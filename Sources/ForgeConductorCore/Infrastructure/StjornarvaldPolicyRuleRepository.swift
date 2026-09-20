// StjornarvaldPolicyRuleRepository.swift
// What: Persists governing policy identity, source-linked rule projections, and utility observations.
// How: The dedicated Stjornarvald SQLite authority stores immutable binding/rule projections and bounded queries.
// Why: Policy rules must survive restart without making an optional external utility a runtime dependency.

import Foundation
import SQLite3

public struct RavenPolicyProjectionReceipt: Sendable, Equatable {
    public let identity: GoverningPolicyIdentity
    public let projectedRuleCount: Int
    public let projectionSHA256: String
    public let utilityObservation: RavenPolicyUtilityObservation
}

public final class StjornarvaldPolicyRuleRepository: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let maximumRulesPerBinding = 1_000
    public static let maximumQueryRules = 1_000
    public static let maximumUtilityObservations = 100

    private enum SQLiteValue { case text(String), integer(Int64), blob(Data), null }
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
            throw StjornarvaldPolicySourceError.unavailable(error.localizedDescription)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StjornarvaldPolicySourceError.unavailable(detail)
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
    public func installRavenBaseline(
        adapter: RavenForgeDevelopmentPolicyAdapter = RavenForgeDevelopmentPolicyAdapter(),
        utility: (any RavenPolicyParityChecking)? = nil
    ) throws -> RavenPolicyProjectionReceipt {
        let identity = RavenForgeDevelopmentPolicyAdapter.identity
        let rules = adapter.rules()
        try Self.validate(identity: identity, rules: rules)
        let utilityObservation = Self.runUtility(utility, identity: identity, rules: rules)
        let encodedRules = try rules.map(Self.encodeRule)
        let projectionData = try JSONSupport.canonicalJSON([
            "binding_id": identity.bindingID,
            "revision": identity.revision,
            "rules": encodedRules.map(\.json),
        ])
        let projectionSHA256 = JSONSupport.sha256Hex(projectionData)

        lock.lock()
        defer { lock.unlock() }
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try insertOrValidateBindingUnlocked(identity)
            for encoded in encodedRules {
                try insertOrValidateRuleUnlocked(
                    encoded.rule,
                    json: encoded.json,
                    digest: encoded.digest,
                    bindingID: identity.bindingID
                )
            }
            try executeUnlocked(
                "INSERT OR IGNORE INTO stj_rule_projection_events(" +
                    "event_id,binding_id,projected_at,projection_sha256,rule_count) VALUES(?,?,?,?,?);",
                [.text(Self.stableEventID("projection\u{0}\(projectionSHA256)")),
                 .text(identity.bindingID), .text(ISO8601.string(from: Date())),
                 .text(projectionSHA256), .integer(Int64(rules.count))]
            )
            try insertUtilityObservationUnlocked(utilityObservation, bindingID: identity.bindingID)
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
        try secureFilesUnlocked()
        return RavenPolicyProjectionReceipt(
            identity: identity,
            projectedRuleCount: rules.count,
            projectionSHA256: projectionSHA256,
            utilityObservation: utilityObservation
        )
    }

    public func activeIdentity() throws -> GoverningPolicyIdentity? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT binding_id,authority,repository_url,policy_version,policy_revision,source_id " +
                "FROM stj_policy_bindings WHERE active=1 ORDER BY installed_at DESC LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let sourceUUID = UUID(uuidString: text(statement, 5)) else {
            throw StjornarvaldPolicySourceError.corruptState("malformed governing policy identity")
        }
        return GoverningPolicyIdentity(
            bindingID: text(statement, 0), authority: text(statement, 1),
            repositoryURL: text(statement, 2), version: text(statement, 3),
            revision: text(statement, 4), sourceID: PolicySourceID(sourceUUID)
        )
    }

    public func rules(limit: Int = 100) throws -> [PolicyRule] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT rule_json FROM stj_policy_rules WHERE active=1 ORDER BY rule_id LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(Int64(min(max(limit, 1), Self.maximumQueryRules)))], to: statement)
        var result: [PolicyRule] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let data = text(statement, 0).data(using: .utf8) else {
                throw StjornarvaldPolicySourceError.corruptState("malformed policy rule projection")
            }
            result.append(try JSONDecoder().decode(PolicyRule.self, from: data))
        }
        return result
    }

    public func utilityObservations(limit: Int = 100) throws -> [RavenPolicyUtilityObservation] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT utility_state,utility_id,summary FROM stj_policy_utility_observations " +
                "ORDER BY sequence DESC LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(Int64(min(max(limit, 1), Self.maximumUtilityObservations)))], to: statement)
        var result: [RavenPolicyUtilityObservation] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let state = RavenPolicyUtilityState(rawValue: text(statement, 0)) else {
                throw StjornarvaldPolicySourceError.corruptState("malformed utility observation")
            }
            result.append(RavenPolicyUtilityObservation(
                state: state,
                utilityID: optionalText(statement, 1),
                summary: text(statement, 2)
            ))
        }
        return result
    }

    private func insertOrValidateBindingUnlocked(_ identity: GoverningPolicyIdentity) throws {
        let existing = try rowUnlocked(
            "SELECT authority,repository_url,policy_version,policy_revision,source_id " +
                "FROM stj_policy_bindings WHERE binding_id=? LIMIT 1;",
            [.text(identity.bindingID)], columns: 5
        )
        if let existing {
            let expected = [identity.authority, identity.repositoryURL, identity.version,
                            identity.revision, identity.sourceID.description]
            guard existing == expected else {
                throw StjornarvaldPolicySourceError.conflict(
                    "the Raven binding ID already names different policy content"
                )
            }
            return
        }
        try executeUnlocked(
            "INSERT INTO stj_policy_bindings(binding_id,authority,repository_url,policy_version," +
                "policy_revision,source_id,active,installed_at) VALUES(?,?,?,?,?,?,1,?);",
            [.text(identity.bindingID), .text(identity.authority), .text(identity.repositoryURL),
             .text(identity.version), .text(identity.revision), .text(identity.sourceID.description),
             .text(ISO8601.string(from: Date()))]
        )
    }

    private func insertOrValidateRuleUnlocked(
        _ rule: PolicyRule,
        json: String,
        digest: String,
        bindingID: String
    ) throws {
        let existing = try rowUnlocked(
            "SELECT rule_sha256 FROM stj_policy_rules WHERE binding_id=? AND rule_id=? LIMIT 1;",
            [.text(bindingID), .text(rule.id.rawValue)], columns: 1
        )
        if let existing {
            guard existing == [digest] else {
                throw StjornarvaldPolicySourceError.conflict(
                    "rule \(rule.id.rawValue) changed without a new governing binding"
                )
            }
            return
        }
        try executeUnlocked(
            "INSERT INTO stj_policy_rules(binding_id,rule_id,source_id,policy_revision,source_path," +
                "source_locator,policy_area,rule_json,rule_sha256,active,projected_at) " +
                "VALUES(?,?,?,?,?,?,?,?,?,1,?);",
            [.text(bindingID), .text(rule.id.rawValue), .text(rule.source.sourceID.description),
             .text(rule.source.revision), .text(rule.source.path), .text(rule.source.locator),
             .text(rule.policyArea), .text(json), .text(digest),
             .text(ISO8601.string(from: Date()))]
        )
    }

    private func insertUtilityObservationUnlocked(
        _ observation: RavenPolicyUtilityObservation,
        bindingID: String
    ) throws {
        let boundedSummary = Self.bounded(observation.summary, maximumBytes: 4_096)
        let digest = JSONSupport.sha256Hex(
            "\(bindingID)\u{0}\(observation.state.rawValue)\u{0}\(observation.utilityID ?? "")\u{0}\(boundedSummary)"
        )
        try executeUnlocked(
            "INSERT OR IGNORE INTO stj_policy_utility_observations(" +
                "event_id,binding_id,observed_at,utility_state,utility_id,summary,observation_sha256) " +
                "VALUES(?,?,?,?,?,?,?);",
            [.text(Self.stableEventID("utility\u{0}\(digest)")), .text(bindingID),
             .text(ISO8601.string(from: Date())), .text(observation.state.rawValue),
             observation.utilityID.map(SQLiteValue.text) ?? .null,
             .text(boundedSummary), .text(digest)]
        )
    }

    private func migrateUnlocked() throws {
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try execUnlocked(
                """
                CREATE TABLE IF NOT EXISTS stj_schema_meta (
                  schema_version INTEGER NOT NULL, created_at TEXT NOT NULL, migrated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS stj_policy_bindings (
                  binding_id TEXT PRIMARY KEY, authority TEXT NOT NULL, repository_url TEXT NOT NULL,
                  policy_version TEXT NOT NULL, policy_revision TEXT NOT NULL, source_id TEXT NOT NULL,
                  active INTEGER NOT NULL CHECK(active IN(0,1)), installed_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS stj_policy_rules (
                  binding_id TEXT NOT NULL REFERENCES stj_policy_bindings(binding_id),
                  rule_id TEXT NOT NULL, source_id TEXT NOT NULL, policy_revision TEXT NOT NULL,
                  source_path TEXT NOT NULL, source_locator TEXT NOT NULL, policy_area TEXT NOT NULL,
                  rule_json TEXT NOT NULL, rule_sha256 TEXT NOT NULL,
                  active INTEGER NOT NULL CHECK(active IN(0,1)), projected_at TEXT NOT NULL,
                  PRIMARY KEY(binding_id,rule_id)
                );
                CREATE INDEX IF NOT EXISTS stj_policy_rules_active
                  ON stj_policy_rules(active,policy_area,rule_id);
                CREATE TABLE IF NOT EXISTS stj_rule_projection_events (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
                  binding_id TEXT NOT NULL, projected_at TEXT NOT NULL,
                  projection_sha256 TEXT NOT NULL UNIQUE, rule_count INTEGER NOT NULL
                );
                CREATE TRIGGER IF NOT EXISTS stj_rule_projection_events_no_update
                  BEFORE UPDATE ON stj_rule_projection_events
                  BEGIN SELECT RAISE(ABORT, 'policy rule projection events are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS stj_rule_projection_events_no_delete
                  BEFORE DELETE ON stj_rule_projection_events
                  BEGIN SELECT RAISE(ABORT, 'policy rule projection events are append-only'); END;
                CREATE TABLE IF NOT EXISTS stj_policy_utility_observations (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
                  binding_id TEXT NOT NULL, observed_at TEXT NOT NULL, utility_state TEXT NOT NULL,
                  utility_id TEXT, summary TEXT NOT NULL, observation_sha256 TEXT NOT NULL UNIQUE
                );
                CREATE TRIGGER IF NOT EXISTS stj_policy_utility_observations_no_update
                  BEFORE UPDATE ON stj_policy_utility_observations
                  BEGIN SELECT RAISE(ABORT, 'policy utility observations are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS stj_policy_utility_observations_no_delete
                  BEFORE DELETE ON stj_policy_utility_observations
                  BEGIN SELECT RAISE(ABORT, 'policy utility observations are append-only'); END;
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
                throw StjornarvaldPolicySourceError.unavailable("unsupported schema")
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
                throw StjornarvaldPolicySourceError.unavailable("unsupported or malformed schema")
            }
            return
        }
        let objects = try scalarIntUnlocked("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        guard objects == 0 else { throw StjornarvaldPolicySourceError.unavailable("unversioned non-empty database") }
    }

    private func secureFilesUnlocked() throws {
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"),
                    URL(fileURLWithPath: databaseURL.path + "-shm")]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func validate(identity: GoverningPolicyIdentity, rules: [PolicyRule]) throws {
        guard !identity.bindingID.isEmpty, !identity.repositoryURL.isEmpty,
              !identity.version.isEmpty, !identity.revision.isEmpty,
              rules.count <= maximumRulesPerBinding else {
            throw StjornarvaldPolicySourceError.invalidRequest("invalid or oversized Raven policy projection")
        }
        guard Set(rules.map(\.id)).count == rules.count else {
            throw StjornarvaldPolicySourceError.invalidRequest("duplicate Raven policy rule identity")
        }
        for rule in rules {
            guard rule.source.sourceID == identity.sourceID,
                  rule.source.revision == identity.revision,
                  !rule.source.path.isEmpty, !rule.source.locator.isEmpty,
                  rule.details != nil, !rule.controlsExecution else {
                throw StjornarvaldPolicySourceError.invalidRequest(
                    "rule \(rule.id.rawValue) lost provenance or crossed the non-interference boundary"
                )
            }
        }
    }

    private static func runUtility(
        _ utility: (any RavenPolicyParityChecking)?,
        identity: GoverningPolicyIdentity,
        rules: [PolicyRule]
    ) -> RavenPolicyUtilityObservation {
        guard let utility else {
            return RavenPolicyUtilityObservation(
                state: .unavailable,
                utilityID: nil,
                summary: "No optional Raven parity utility was supplied; direct pinned-source rules remain active."
            )
        }
        do {
            let report = try utility.verify(identity: identity, rules: rules)
            return RavenPolicyUtilityObservation(
                state: .passed,
                utilityID: bounded(report.utilityID, maximumBytes: 256),
                summary: bounded(report.summary, maximumBytes: 4_096)
            )
        } catch {
            return RavenPolicyUtilityObservation(
                state: .failed,
                utilityID: String(describing: type(of: utility)),
                summary: "Optional Raven parity utility failed; direct pinned-source rules remain active: " +
                    bounded(error.localizedDescription, maximumBytes: 3_840)
            )
        }
    }

    private static func encodeRule(_ rule: PolicyRule) throws -> (rule: PolicyRule, json: String, digest: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rule)
        guard let json = String(data: data, encoding: .utf8) else {
            throw StjornarvaldPolicySourceError.corruptState("rule projection is not UTF-8")
        }
        return (rule, json, JSONSupport.sha256Hex(data))
    }

    private static func stableEventID(_ value: String) -> String {
        var characters = Array(JSONSupport.sha256Hex(value).prefix(32))
        characters[12] = "5"
        characters[16] = "8"
        let raw = String(characters)
        return "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-" +
            "\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))"
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var count = 0
        for character in value {
            let width = String(character).utf8.count
            if count + width > maximumBytes { break }
            result.append(character)
            count += width
        }
        return result
    }

    private func execUnlocked(_ sql: String) throws {
        guard let database else { throw StjornarvaldPolicySourceError.unavailable("closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw StjornarvaldPolicySourceError.sqlite(detail)
        }
    }

    private func executeUnlocked(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteErrorUnlocked() }
    }

    private func rowUnlocked(
        _ sql: String,
        _ values: [SQLiteValue],
        columns: Int32
    ) throws -> [String]? {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return (0..<columns).map { text(statement, $0) }
    }

    private func scalarIntUnlocked(_ sql: String) throws -> Int {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw StjornarvaldPolicySourceError.unavailable("closed") }
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
            case .blob(let value):
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.sqliteTransient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteErrorUnlocked() }
        }
    }

    private func sqliteErrorUnlocked() -> StjornarvaldPolicySourceError {
        guard let database else { return .unavailable("closed") }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }
}
