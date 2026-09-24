// StjornarvaldObservationRepository.swift
// What: Persists immutable development observations, evaluator ownership, cursors, and fault receipts.
// How: One schema-versioned SQLite authority provides idempotent intake and an expiring single-writer lease.
// Why: Policy evaluation must resume after failure without delaying or controlling the observed development path.

import Foundation
import SQLite3

public enum StjornarvaldObservationError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case invalidObservation(String)
    case conflict(String)
    case leaseLost(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Observation repository unavailable: \(detail)"
        case .invalidObservation(let detail): "Invalid development observation: \(detail)"
        case .conflict(let detail): "Observation conflict: \(detail)"
        case .leaseLost(let detail): "Evaluator lease lost: \(detail)"
        case .sqlite(let detail): "Observation SQLite error: \(detail)"
        }
    }
}

public struct SequencedDevelopmentObservation: Sendable, Equatable {
    public let sequence: Int64
    public let observation: DevelopmentObservation
}

public struct DevelopmentObservationReceipt: Sendable, Equatable {
    public let sequence: Int64
    public let observationID: UUID
    public let idempotencyKey: String
    public let observationSHA256: String
}

public struct StjornarvaldEvaluatorIdentity: Sendable, Equatable {
    public let evaluatorID: String
    public let processID: Int32
    public let bootID: String

    public init(evaluatorID: String, processID: Int32, bootID: String) {
        self.evaluatorID = evaluatorID
        self.processID = processID
        self.bootID = bootID
    }
}

public struct StjornarvaldEvaluatorLease: Sendable, Equatable {
    public let owner: StjornarvaldEvaluatorIdentity
    public let expiresAt: Date
    public let observationCursor: Int64
}

public enum StjornarvaldEvaluatorLeaseClaim: Sendable, Equatable {
    case acquired(StjornarvaldEvaluatorLease)
    case contended(StjornarvaldEvaluatorLease)
}

public struct StjornarvaldDetectorFault: Codable, Sendable, Equatable {
    public let detectorID: String
    public let summary: String

    public init(detectorID: String, summary: String) {
        self.detectorID = detectorID
        self.summary = summary
    }
}

public struct StjornarvaldEvaluationReceipt: Sendable, Equatable {
    public let observationSequence: Int64
    public let observationID: UUID
    public let evaluatorID: String
    public let findingCount: Int
    public let detectorFaultCount: Int
    public let evaluatedAt: Date
    public let controlsExecution: Bool
}

/// Bounded presentation of actual evaluation activity, distinct from violations.
public struct PolicyEvaluationActivity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let summary: String
    public let evaluatedAt: String
    public let findingCount: Int
    public let detectorFaultCount: Int
}

public enum DevelopmentObservationSubmissionDisposition: Sendable, Equatable {
    case persisted(DevelopmentObservationReceipt)
    case deferred(observationID: UUID)
    case rejected(observationID: UUID)
}

public final class StjornarvaldObservationRepository: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let maximumObservationBytes = 262_144
    public static let maximumPendingQuery = 256
    public static let maximumFaultQuery = 1_000

    private enum SQLiteValue { case text(String), integer(Int64), double(Double), null }
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let lock = NSLock()
    private var database: OpaquePointer?
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StjornarvaldObservationError.unavailable(error.localizedDescription)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StjornarvaldObservationError.unavailable(detail)
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
    public func submit(_ observation: DevelopmentObservation) throws -> DevelopmentObservationReceipt {
        try Self.validate(observation)
        let data = try Self.encode(observation)
        let digest = JSONSupport.sha256Hex(data)
        let json = String(decoding: data, as: UTF8.self)
        lock.lock()
        defer { lock.unlock() }

        if let existing = try receiptUnlocked(idempotencyKey: observation.idempotencyKey) {
            guard existing.observationID == observation.id,
                  existing.observationSHA256 == digest else {
                throw StjornarvaldObservationError.conflict(
                    "idempotency key already names different observation content"
                )
            }
            return existing
        }
        if let existing = try receiptUnlocked(observationID: observation.id) {
            guard existing.idempotencyKey == observation.idempotencyKey,
                  existing.observationSHA256 == digest else {
                throw StjornarvaldObservationError.conflict(
                    "observation ID already names different content"
                )
            }
            return existing
        }
        try executeUnlocked(
            "INSERT INTO stj_observations(observation_id,idempotency_key,received_at," +
                "observation_json,observation_sha256) VALUES(?,?,?,?,?);",
            [.text(observation.id.uuidString.lowercased()), .text(observation.idempotencyKey),
             .text(ISO8601.string(from: Date())), .text(json), .text(digest)]
        )
        guard let receipt = try receiptUnlocked(observationID: observation.id) else {
            throw StjornarvaldObservationError.sqlite("inserted observation is unavailable")
        }
        return receipt
    }

    public func pending(after sequence: Int64, limit: Int = 32) throws -> [SequencedDevelopmentObservation] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT sequence,observation_json FROM stj_observations WHERE sequence>? " +
                "ORDER BY sequence LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .integer(max(sequence, 0)),
            .integer(Int64(min(max(limit, 1), Self.maximumPendingQuery))),
        ], to: statement)
        var result: [SequencedDevelopmentObservation] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let data = text(statement, 1).data(using: .utf8),
                  let observation = try? Self.decoder().decode(DevelopmentObservation.self, from: data) else {
                throw StjornarvaldObservationError.sqlite("malformed durable observation")
            }
            result.append(SequencedDevelopmentObservation(
                sequence: sqlite3_column_int64(statement, 0), observation: observation
            ))
        }
        return result
    }

    public func claimLease(
        identity: StjornarvaldEvaluatorIdentity,
        duration: TimeInterval,
        now: Date = Date()
    ) throws -> StjornarvaldEvaluatorLeaseClaim {
        let boundedDuration = min(max(duration, 1), 300)
        let expiration = now.addingTimeInterval(boundedDuration)
        try Self.validate(identity)
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            let current = try leaseUnlocked()
            if let current,
               current.owner != identity,
               current.expiresAt > now {
                try execUnlocked("COMMIT;")
                return .contended(current)
            }
            if current == nil {
                try executeUnlocked(
                    "INSERT INTO stj_evaluator_lease(singleton,evaluator_id,process_id,boot_id," +
                        "expires_at,observation_cursor) VALUES(1,?,?,?,?,0);",
                    [.text(identity.evaluatorID), .integer(Int64(identity.processID)),
                     .text(identity.bootID), .double(expiration.timeIntervalSince1970)]
                )
            } else {
                try executeUnlocked(
                    "UPDATE stj_evaluator_lease SET evaluator_id=?,process_id=?,boot_id=?," +
                        "expires_at=? WHERE singleton=1;",
                    [.text(identity.evaluatorID), .integer(Int64(identity.processID)),
                     .text(identity.bootID), .double(expiration.timeIntervalSince1970)]
                )
            }
            guard let acquired = try leaseUnlocked() else {
                throw StjornarvaldObservationError.sqlite("claimed evaluator lease is unavailable")
            }
            try execUnlocked("COMMIT;")
            return .acquired(acquired)
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func renewLease(
        identity: StjornarvaldEvaluatorIdentity,
        duration: TimeInterval,
        now: Date = Date()
    ) throws -> StjornarvaldEvaluatorLease {
        let expiration = now.addingTimeInterval(min(max(duration, 1), 300))
        try Self.validate(identity)
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(
            "UPDATE stj_evaluator_lease SET expires_at=? WHERE singleton=1 " +
                "AND evaluator_id=? AND process_id=? AND boot_id=? AND expires_at>?;",
            [.double(expiration.timeIntervalSince1970), .text(identity.evaluatorID),
             .integer(Int64(identity.processID)), .text(identity.bootID),
             .double(now.timeIntervalSince1970)]
        )
        guard let database, sqlite3_changes(database) == 1,
              let current = try leaseUnlocked(), current.owner == identity else {
            throw StjornarvaldObservationError.leaseLost(identity.evaluatorID)
        }
        return current
    }

    public func releaseLease(identity: StjornarvaldEvaluatorIdentity) throws {
        try Self.validate(identity)
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(
            "UPDATE stj_evaluator_lease SET expires_at=0 WHERE singleton=1 AND evaluator_id=? " +
                "AND process_id=? AND boot_id=?;",
            [.text(identity.evaluatorID), .integer(Int64(identity.processID)),
             .text(identity.bootID)]
        )
    }

    @discardableResult
    public func completeEvaluation(
        observationSequence: Int64,
        observationID: UUID,
        identity: StjornarvaldEvaluatorIdentity,
        findingCount: Int,
        detectorFaults: [StjornarvaldDetectorFault],
        now: Date = Date()
    ) throws -> StjornarvaldEvaluationReceipt {
        let boundedFaults = Array(detectorFaults.prefix(64))
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            if let receipt = try evaluationReceiptUnlocked(sequence: observationSequence) {
                guard receipt.observationID == observationID else {
                    throw StjornarvaldObservationError.conflict(
                        "evaluation sequence already names another observation"
                    )
                }
                try execUnlocked("COMMIT;")
                return receipt
            }
            guard let lease = try leaseUnlocked(), lease.owner == identity,
                  lease.expiresAt > now else {
                throw StjornarvaldObservationError.leaseLost(identity.evaluatorID)
            }
            guard observationSequence == lease.observationCursor + 1 else {
                throw StjornarvaldObservationError.conflict(
                    "evaluation must advance the durable observation cursor by one"
                )
            }
            guard try observationIDUnlocked(sequence: observationSequence) == observationID else {
                throw StjornarvaldObservationError.conflict(
                    "evaluation receipt does not match the durable observation"
                )
            }
            try executeUnlocked(
                "INSERT INTO stj_observation_evaluations(observation_sequence,observation_id," +
                    "evaluator_id,evaluated_at,finding_count,detector_fault_count,controls_execution) " +
                    "VALUES(?,?,?,?,?,?,0);",
                [.integer(observationSequence), .text(observationID.uuidString.lowercased()),
                 .text(identity.evaluatorID), .text(ISO8601.string(from: now)),
                 .integer(Int64(max(findingCount, 0))), .integer(Int64(boundedFaults.count))]
            )
            for fault in boundedFaults {
                try executeUnlocked(
                    "INSERT INTO stj_detector_faults(fault_id,observation_sequence,detector_id," +
                        "summary,recorded_at) VALUES(?,?,?,?,?);",
                    [.text(Self.stableID(
                        "\(observationID.uuidString)\u{0}\(fault.detectorID)\u{0}\(fault.summary)"
                    )), .integer(observationSequence),
                     .text(Self.bounded(fault.detectorID, bytes: 256)),
                     .text(Self.bounded(fault.summary, bytes: 4_096)),
                     .text(ISO8601.string(from: now))]
                )
            }
            try executeUnlocked(
                "UPDATE stj_evaluator_lease SET observation_cursor=? " +
                    "WHERE singleton=1 AND evaluator_id=? AND process_id=? AND boot_id=?;",
                [.integer(observationSequence), .text(identity.evaluatorID),
                 .integer(Int64(identity.processID)), .text(identity.bootID)]
            )
            guard let receipt = try evaluationReceiptUnlocked(sequence: observationSequence) else {
                throw StjornarvaldObservationError.sqlite("evaluation receipt is unavailable")
            }
            try execUnlocked("COMMIT;")
            return receipt
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func evaluationReceipts(after sequence: Int64 = 0, limit: Int = 100) throws
        -> [StjornarvaldEvaluationReceipt] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT observation_sequence,observation_id,evaluator_id,finding_count," +
                "detector_fault_count,evaluated_at,controls_execution " +
                "FROM stj_observation_evaluations WHERE observation_sequence>? " +
                "ORDER BY observation_sequence LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(max(sequence, 0)), .integer(Int64(min(max(limit, 1), 1_000)))], to: statement)
        var result: [StjornarvaldEvaluationReceipt] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            result.append(try decodeEvaluationReceipt(statement))
        }
        return result
    }

    public func recentEvaluationActivity(
        limit: Int = 50, projectID: String? = nil, projectGeneration: UInt64? = nil
    ) throws -> [PolicyEvaluationActivity] {
        lock.lock()
        defer { lock.unlock() }
        let scoped = projectID != nil
        let statement = try prepareUnlocked(
            "SELECT e.observation_id,substr(json_extract(o.observation_json,'$.summary'),1,2048)," +
                "e.evaluated_at,e.finding_count,e.detector_fault_count " +
                "FROM stj_observation_evaluations e JOIN stj_observations o " +
                "ON o.sequence=e.observation_sequence " +
                (scoped ? "WHERE json_extract(o.observation_json,'$.scope.projectID')=? AND json_extract(o.observation_json,'$.scope.projectGeneration')=? " : "") +
                "ORDER BY e.observation_sequence DESC LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        var values: [SQLiteValue] = []
        if let projectID {
            guard let projectGeneration, projectGeneration <= UInt64(Int64.max) else { return [] }
            values = [.text(projectID), .integer(Int64(projectGeneration))]
        }
        values.append(.integer(Int64(min(max(limit, 1), 100))))
        try bind(values, to: statement)
        var result: [PolicyEvaluationActivity] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw StjornarvaldObservationError.sqlite("Unable to read policy evaluation activity")
            }
            result.append(PolicyEvaluationActivity(
                id: text(statement, 0), summary: text(statement, 1), evaluatedAt: text(statement, 2),
                findingCount: Int(sqlite3_column_int64(statement, 3)),
                detectorFaultCount: Int(sqlite3_column_int64(statement, 4))
            ))
        }
        return result
    }

    public func detectorFaults(limit: Int = 100) throws -> [StjornarvaldDetectorFault] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT detector_id,summary FROM stj_detector_faults ORDER BY sequence DESC LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(Int64(min(max(limit, 1), Self.maximumFaultQuery)))], to: statement)
        var result: [StjornarvaldDetectorFault] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            result.append(StjornarvaldDetectorFault(
                detectorID: text(statement, 0), summary: text(statement, 1)
            ))
        }
        return result
    }

    private func migrateUnlocked() throws {
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try execUnlocked(
                """
                CREATE TABLE IF NOT EXISTS stj_schema_meta (
                  schema_version INTEGER NOT NULL, created_at TEXT NOT NULL, migrated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS stj_observations (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  observation_id TEXT NOT NULL UNIQUE, idempotency_key TEXT NOT NULL UNIQUE,
                  received_at TEXT NOT NULL, observation_json TEXT NOT NULL,
                  observation_sha256 TEXT NOT NULL
                );
                CREATE TRIGGER IF NOT EXISTS stj_observations_no_update
                  BEFORE UPDATE ON stj_observations
                  BEGIN SELECT RAISE(ABORT, 'development observations are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS stj_observations_no_delete
                  BEFORE DELETE ON stj_observations
                  BEGIN SELECT RAISE(ABORT, 'development observations are append-only'); END;
                CREATE TABLE IF NOT EXISTS stj_evaluator_lease (
                  singleton INTEGER PRIMARY KEY CHECK(singleton=1), evaluator_id TEXT NOT NULL,
                  process_id INTEGER NOT NULL, boot_id TEXT NOT NULL, expires_at REAL NOT NULL,
                  observation_cursor INTEGER NOT NULL CHECK(observation_cursor >= 0)
                );
                CREATE TABLE IF NOT EXISTS stj_observation_evaluations (
                  observation_sequence INTEGER PRIMARY KEY REFERENCES stj_observations(sequence),
                  observation_id TEXT NOT NULL UNIQUE, evaluator_id TEXT NOT NULL,
                  evaluated_at TEXT NOT NULL, finding_count INTEGER NOT NULL,
                  detector_fault_count INTEGER NOT NULL,
                  controls_execution INTEGER NOT NULL CHECK(controls_execution=0)
                );
                CREATE TRIGGER IF NOT EXISTS stj_observation_evaluations_no_update
                  BEFORE UPDATE ON stj_observation_evaluations
                  BEGIN SELECT RAISE(ABORT, 'observation evaluations are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS stj_observation_evaluations_no_delete
                  BEFORE DELETE ON stj_observation_evaluations
                  BEGIN SELECT RAISE(ABORT, 'observation evaluations are append-only'); END;
                CREATE TABLE IF NOT EXISTS stj_detector_faults (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT, fault_id TEXT NOT NULL UNIQUE,
                  observation_sequence INTEGER NOT NULL REFERENCES stj_observations(sequence),
                  detector_id TEXT NOT NULL, summary TEXT NOT NULL, recorded_at TEXT NOT NULL
                );
                CREATE TRIGGER IF NOT EXISTS stj_detector_faults_no_update
                  BEFORE UPDATE ON stj_detector_faults
                  BEGIN SELECT RAISE(ABORT, 'detector faults are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS stj_detector_faults_no_delete
                  BEFORE DELETE ON stj_detector_faults
                  BEGIN SELECT RAISE(ABORT, 'detector faults are append-only'); END;
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
                throw StjornarvaldObservationError.unavailable("unsupported schema")
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
                throw StjornarvaldObservationError.unavailable("unsupported or malformed schema")
            }
            return
        }
        let count = try scalarIntUnlocked("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        guard count == 0 else {
            throw StjornarvaldObservationError.unavailable("unversioned non-empty database")
        }
    }

    fileprivate static func validate(_ observation: DevelopmentObservation) throws {
        let strings = [observation.idempotencyKey, observation.subjectIdentity,
                       observation.summary, observation.payloadSHA256]
        let digestBytes = Array(observation.payloadSHA256.utf8)
        let scopeStrings = [observation.scope.projectID, observation.scope.runID,
                            observation.scope.sessionID, observation.scope.clientID].compactMap { $0 }
        guard !observation.idempotencyKey.isEmpty,
              observation.idempotencyKey.utf8.count <= 512,
              strings.dropFirst().allSatisfy({ $0.utf8.count <= 16_384 }),
              scopeStrings.allSatisfy({ $0.utf8.count <= 4_096 }),
              observation.scope.projectGeneration.map({ $0 >= 0 }) ?? true,
              observation.evidenceReferences.count <= 64,
              observation.evidenceReferences.allSatisfy({ $0.utf8.count <= 4_096 }),
              digestBytes.count == 64,
              digestBytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (observation.details?.nativeTarget?.shippingRuntimePaths.count ?? 0) <= 10_000,
              observation.details?.nativeTarget?.shippingRuntimePaths
                .allSatisfy({ $0.utf8.count <= 4_096 }) ?? true,
              try encode(observation).count <= maximumObservationBytes else {
            throw StjornarvaldObservationError.invalidObservation("observation exceeds bounds or is malformed")
        }
    }

    private static func validate(_ identity: StjornarvaldEvaluatorIdentity) throws {
        guard !identity.evaluatorID.isEmpty, identity.evaluatorID.utf8.count <= 256,
              !identity.bootID.isEmpty, identity.bootID.utf8.count <= 256,
              identity.processID > 0 else {
            throw StjornarvaldObservationError.invalidObservation("invalid evaluator identity")
        }
    }

    private func receiptUnlocked(idempotencyKey: String) throws -> DevelopmentObservationReceipt? {
        try receiptUnlocked(
            sql: "SELECT sequence,observation_id,idempotency_key,observation_sha256 " +
                "FROM stj_observations WHERE idempotency_key=? LIMIT 1;",
            value: .text(idempotencyKey)
        )
    }

    private func receiptUnlocked(observationID: UUID) throws -> DevelopmentObservationReceipt? {
        try receiptUnlocked(
            sql: "SELECT sequence,observation_id,idempotency_key,observation_sha256 " +
                "FROM stj_observations WHERE observation_id=? LIMIT 1;",
            value: .text(observationID.uuidString.lowercased())
        )
    }

    private func receiptUnlocked(sql: String, value: SQLiteValue) throws -> DevelopmentObservationReceipt? {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        try bind([value], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let id = UUID(uuidString: text(statement, 1)) else {
            throw StjornarvaldObservationError.sqlite("malformed observation receipt")
        }
        return DevelopmentObservationReceipt(
            sequence: sqlite3_column_int64(statement, 0), observationID: id,
            idempotencyKey: text(statement, 2), observationSHA256: text(statement, 3)
        )
    }

    private func leaseUnlocked() throws -> StjornarvaldEvaluatorLease? {
        let statement = try prepareUnlocked(
            "SELECT evaluator_id,process_id,boot_id,expires_at,observation_cursor " +
                "FROM stj_evaluator_lease WHERE singleton=1;"
        )
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        let rawProcessID = sqlite3_column_int64(statement, 1)
        guard let processID = Int32(exactly: rawProcessID) else {
            throw StjornarvaldObservationError.sqlite("malformed evaluator process identity")
        }
        return StjornarvaldEvaluatorLease(
            owner: StjornarvaldEvaluatorIdentity(
                evaluatorID: text(statement, 0),
                processID: processID,
                bootID: text(statement, 2)
            ),
            expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            observationCursor: sqlite3_column_int64(statement, 4)
        )
    }

    private func observationIDUnlocked(sequence: Int64) throws -> UUID? {
        let statement = try prepareUnlocked(
            "SELECT observation_id FROM stj_observations WHERE sequence=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(sequence)], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return UUID(uuidString: text(statement, 0))
    }

    private func evaluationReceiptUnlocked(sequence: Int64) throws -> StjornarvaldEvaluationReceipt? {
        let statement = try prepareUnlocked(
            "SELECT observation_sequence,observation_id,evaluator_id,finding_count," +
                "detector_fault_count,evaluated_at,controls_execution " +
                "FROM stj_observation_evaluations WHERE observation_sequence=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(sequence)], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        return try decodeEvaluationReceipt(statement)
    }

    private func decodeEvaluationReceipt(_ statement: OpaquePointer) throws
        -> StjornarvaldEvaluationReceipt {
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              let observationID = UUID(uuidString: text(statement, 1)),
              let evaluatedAt = ISO8601.date(from: text(statement, 5)) else {
            throw StjornarvaldObservationError.sqlite("malformed evaluation receipt")
        }
        return StjornarvaldEvaluationReceipt(
            observationSequence: sqlite3_column_int64(statement, 0),
            observationID: observationID, evaluatorID: text(statement, 2),
            findingCount: Int(sqlite3_column_int64(statement, 3)),
            detectorFaultCount: Int(sqlite3_column_int64(statement, 4)),
            evaluatedAt: evaluatedAt,
            controlsExecution: sqlite3_column_int64(statement, 6) != 0
        )
    }

    private func secureFilesUnlocked() throws {
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"),
                    URL(fileURLWithPath: databaseURL.path + "-shm")]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func encode(_ observation: DevelopmentObservation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(observation)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func stableID(_ value: String) -> String {
        var characters = Array(JSONSupport.sha256Hex(value).prefix(32))
        characters[12] = "5"
        characters[16] = "8"
        let raw = String(characters)
        return "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-" +
            "\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))"
    }

    private static func bounded(_ value: String, bytes maximum: Int) -> String {
        var result = ""
        var count = 0
        for character in value {
            let width = String(character).utf8.count
            if count + width > maximum { break }
            result.append(character)
            count += width
        }
        return result
    }

    private func execUnlocked(_ sql: String) throws {
        guard let database else { throw StjornarvaldObservationError.unavailable("closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw StjornarvaldObservationError.sqlite(detail)
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
        guard let database else { throw StjornarvaldObservationError.unavailable("closed") }
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
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteErrorUnlocked() }
        }
    }

    private func sqliteErrorUnlocked() -> StjornarvaldObservationError {
        guard let database else { return .unavailable("closed") }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}

public final class StjornarvaldObservationService: PolicyObservationSubmitting, @unchecked Sendable {
    private struct OutboxEnvelope: Codable, Equatable {
        let observation: DevelopmentObservation
    }

    private let lock = NSLock()
    private let repository: StjornarvaldObservationRepository?
    private let outboxURL: URL
    private let diagnostics: @Sendable (String) -> Void
    private var emergency: [OutboxEnvelope] = []
    private static let emergencyLimit = 32

    public init(
        databaseURL: URL,
        outboxURL: URL,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.outboxURL = outboxURL
        self.diagnostics = diagnostics
        do { repository = try StjornarvaldObservationRepository(databaseURL: databaseURL) }
        catch {
            repository = nil
            diagnostics("stjornarvald observation repository unavailable: \(error.localizedDescription)")
        }
        reconcileOutbox()
    }

    public func submit(_ observation: DevelopmentObservation) async {
        _ = submitWithDisposition(observation)
    }

    @discardableResult
    public func submitWithDisposition(
        _ observation: DevelopmentObservation
    ) -> DevelopmentObservationSubmissionDisposition {
        do { try StjornarvaldObservationRepository.validate(observation) }
        catch {
            diagnostics("stjornarvald observation rejected by bounds: \(error.localizedDescription)")
            return .rejected(observationID: observation.id)
        }
        if let repository {
            do { return .persisted(try repository.submit(observation)) }
            catch let error as StjornarvaldObservationError {
                switch error {
                case .conflict, .invalidObservation:
                    diagnostics("stjornarvald observation rejected: \(error.localizedDescription)")
                    return .rejected(observationID: observation.id)
                case .unavailable, .leaseLost, .sqlite:
                    diagnostics("stjornarvald observation write deferred: \(error.localizedDescription)")
                }
            } catch {
                diagnostics("stjornarvald observation write deferred: \(error.localizedDescription)")
            }
        }
        let envelope = OutboxEnvelope(observation: observation)
        if persistOutbox(envelope) { return .deferred(observationID: observation.id) }
        lock.lock()
        if emergency.count == Self.emergencyLimit { emergency.removeFirst() }
        emergency.append(envelope)
        lock.unlock()
        diagnostics("stjornarvald observation outbox unavailable; retained in bounded memory")
        return .deferred(observationID: observation.id)
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
                envelope.observation.id.uuidString.lowercased() + ".json"
            )
            if manager.fileExists(atPath: destination.path) {
                let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
                guard data.count <= StjornarvaldObservationRepository.maximumObservationBytes,
                      try decoder().decode(OutboxEnvelope.self, from: data) == envelope else {
                    diagnostics("stjornarvald observation outbox identity conflict")
                    return false
                }
                return true
            }
            guard boundedOutboxFiles(maximum: 10_000).count < 10_000 else {
                diagnostics("stjornarvald observation outbox reached its 10000-item bound")
                return false
            }
            try encoder.encode(envelope).write(to: destination, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch {
            diagnostics("stjornarvald observation outbox write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func reconcileOutbox() {
        guard let repository else { return }
        let manager = FileManager.default
        for file in boundedOutboxFiles(maximum: 1_000).sorted(by: { $0.path < $1.path }) {
            do {
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                guard data.count <= StjornarvaldObservationRepository.maximumObservationBytes else {
                    diagnostics("stjornarvald observation outbox item exceeds its byte bound")
                    continue
                }
                let envelope = try decoder().decode(OutboxEnvelope.self, from: data)
                _ = try repository.submit(envelope.observation)
                try manager.removeItem(at: file)
            } catch {
                diagnostics("stjornarvald observation reconciliation deferred: \(error.localizedDescription)")
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

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
