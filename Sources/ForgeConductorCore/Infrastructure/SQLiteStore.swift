// SQLiteStore.swift
// What: Implements durable presence, session, binding, and audit repositories.
// How: One serialized SQLite connection owns schema migration, prepared statements,
// transactions, bounded queries, and typed row conversion.
// Why: A single storage adapter preserves consistency while satisfying narrow domain ports.

import Foundation
import SQLite3

/// Normalizes SQLite adapter failures into stable, user-readable error categories.
public enum StoreError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case execFailed(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let s): "SQLite open failed: \(s)"
        case .execFailed(let s): "SQLite error: \(s)"
        case .notFound(let s): s
        }
    }
}

/// SQLite3-backed store using the system library.
public final class SQLiteStore: PresenceStore, SessionStore, AuditReading, @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: URL
    private let clock: any Clock

    /// SQLite copies the bound text; required so Swift string buffers can free.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL, clock: any Clock = SystemClock()) throws {
        self.path = path
        self.clock = clock
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw StoreError.openFailed(msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        // GUI manager + MCP serve share one home. Without a busy timeout, a locked
        // store can stall serve startup long enough for LM Studio's ~60s plugin timeout.
        try exec("PRAGMA busy_timeout=3000;")
        try migrate()
    }

    deinit {
        close()
    }

    /// Explicit close for tests that delete the home directory after bootstrap.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - Schema

    public func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS memory_notes (
            key TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            tags_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS agent_sessions (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            client_id TEXT,
            status TEXT NOT NULL,
            summary TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS presence (
            client_id TEXT PRIMARY KEY,
            host_kind TEXT,
            pid INTEGER,
            cwd TEXT,
            last_heartbeat TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            client_id TEXT,
            tool TEXT NOT NULL,
            args_digest TEXT,
            args_json TEXT,
            status TEXT,
            duration_ms INTEGER,
            error TEXT
        );
        """)
        let version: Int = try queryInt("SELECT version FROM schema_version LIMIT 1") ?? 0
        if version == 0 {
            try exec("INSERT INTO schema_version(version) VALUES (2);")
        } else if version < 2 {
            try exec("UPDATE schema_version SET version = 2;")
        }
    }

    // MARK: - Sessions

    public func sessionStart(agentID: String, clientID: ClientID?) throws -> AgentSession {
        let now = clock.now()
        let s = AgentSession(agentID: agentID, clientID: clientID, status: .open, createdAt: now, updatedAt: now)
        let ts = ISO8601.string(from: now)
        try withStatement(
            "INSERT INTO agent_sessions (id, agent_id, client_id, status, summary, created_at, updated_at) VALUES (?,?,?,?,NULL,?,?)"
        ) { stmt in
            bind(stmt, 1, s.id.rawValue)
            bind(stmt, 2, agentID)
            bind(stmt, 3, clientID?.rawValue)
            bind(stmt, 4, SessionStatus.open.rawValue)
            bind(stmt, 5, ts)
            bind(stmt, 6, ts)
            try stepDone(stmt)
        }
        return s
    }

    public func sessionGet(id: SessionID) throws -> AgentSession? {
        try withStatement(
            "SELECT id, agent_id, client_id, status, summary, created_at, updated_at FROM agent_sessions WHERE id = ?"
        ) { stmt in
            bind(stmt, 1, id.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return mapSession(stmt)
        }
    }

    public func sessionEnd(id: SessionID, summary: String?) throws -> AgentSession {
        guard try sessionGet(id: id) != nil else {
            throw StoreError.notFound("Unknown agent session: \(id.rawValue)")
        }
        let ts = ISO8601.string(from: clock.now())
        try withStatement(
            "UPDATE agent_sessions SET status='closed', summary=?, updated_at=? WHERE id=?"
        ) { stmt in
            bind(stmt, 1, summary)
            bind(stmt, 2, ts)
            bind(stmt, 3, id.rawValue)
            try stepDone(stmt)
        }
        guard let s = try sessionGet(id: id) else {
            throw StoreError.notFound("session missing after end")
        }
        return s
    }

    public func sessionTouch(id: SessionID) throws -> Bool {
        let ts = ISO8601.string(from: clock.now())
        try withStatement(
            """
            UPDATE agent_sessions SET updated_at=?
            WHERE id=? AND status IN ('open','active','running','started')
            """
        ) { stmt in
            bind(stmt, 1, ts)
            bind(stmt, 2, id.rawValue)
            try stepDone(stmt)
        }
        return changes() > 0
    }

    public func sessionList(agentID: String? = nil, status: SessionStatus? = nil) throws -> [AgentSession] {
        var sql = "SELECT id, agent_id, client_id, status, summary, created_at, updated_at FROM agent_sessions WHERE 1=1"
        if agentID != nil { sql += " AND agent_id = ?" }
        if status != nil { sql += " AND status = ?" }
        sql += " ORDER BY created_at DESC"
        return try withStatement(sql) { stmt in
            var i: Int32 = 1
            if let agentID { bind(stmt, i, agentID); i += 1 }
            if let status { bind(stmt, i, status.rawValue); i += 1 }
            var out: [AgentSession] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(mapSession(stmt))
            }
            return out
        }
    }

    public func sessionCloseOpen(
        for clientID: ClientID,
        except: SessionID? = nil,
        summary: String
    ) throws -> [AgentSession] {
        var closed: [AgentSession] = []
        var seen = Set<String>()
        for st in [SessionStatus.open, .active, .running, .started] {
            for s in try sessionList(status: st) where s.clientID == clientID {
                if seen.contains(s.id.rawValue) { continue }
                seen.insert(s.id.rawValue)
                if let except, s.id == except { continue }
                closed.append(try sessionEnd(id: s.id, summary: summary))
            }
        }
        return closed
    }

    // MARK: - Memory notes

    /// Maximum key length accepted by MCP memory tools (UTF-8 bytes).
    public static let memoryKeyMaxBytes = 512
    /// Maximum body length accepted by MCP memory tools (UTF-8 bytes).
    public static let memoryBodyMaxBytes = 512 * 1024
    /// Soft cap on list/search result rows.
    public static let memoryQueryDefaultLimit = 50
    public static let memoryQueryMaxLimit = 200

    public func memorySet(key: String, body: String, tags: [String] = []) throws {
        let ts = ISO8601.string(from: clock.now())
        let tagsArr = try JSONSerialization.data(withJSONObject: tags)
        let tagsStr = String(data: tagsArr, encoding: .utf8) ?? "[]"
        try withStatement(
            """
            INSERT INTO memory_notes(key, body, tags_json, created_at, updated_at)
            VALUES(?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET body=excluded.body, tags_json=excluded.tags_json, updated_at=excluded.updated_at
            """
        ) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, body)
            bind(stmt, 3, tagsStr)
            bind(stmt, 4, ts)
            bind(stmt, 5, ts)
            try stepDone(stmt)
        }
    }

    public func memoryGet(key: String) throws -> String? {
        try memoryGetNote(key: key)?.body
    }

    public func memoryGetNote(key: String) throws -> MemoryNote? {
        try withStatement(
            "SELECT key, body, tags_json, created_at, updated_at FROM memory_notes WHERE key = ?"
        ) { stmt in
            bind(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return mapMemoryNote(stmt)
        }
    }

    public func memoryDelete(key: String) throws -> Bool {
        try withStatement("DELETE FROM memory_notes WHERE key = ?") { stmt in
            bind(stmt, 1, key)
            try stepDone(stmt)
        }
        return changes() > 0
    }

    /// List durable notes, newest updates first.
    /// - Parameters:
    ///   - prefix: Optional key prefix filter (e.g. `project/`).
    ///   - tag: Optional exact tag match (JSON array contains).
    ///   - includeSystem: When false (default), hides `agent_run/` and `agent_active/` keys.
    ///   - limit: Max rows (clamped to `memoryQueryMaxLimit`).
    public func memoryList(
        prefix: String? = nil,
        tag: String? = nil,
        includeSystem: Bool = false,
        limit: Int = SQLiteStore.memoryQueryDefaultLimit
    ) throws -> [MemoryNote] {
        let capped = min(max(limit, 1), Self.memoryQueryMaxLimit)
        var sql = """
        SELECT key, body, tags_json, created_at, updated_at
        FROM memory_notes WHERE 1=1
        """
        if prefix != nil { sql += " AND key LIKE ? ESCAPE '\\'" }
        if !includeSystem {
            sql += " AND key NOT LIKE 'agent\\_run/%' ESCAPE '\\' AND key NOT LIKE 'agent\\_active/%' ESCAPE '\\'"
        }
        sql += " ORDER BY updated_at DESC LIMIT ?"

        return try withStatement(sql) { stmt in
            var i: Int32 = 1
            if let prefix {
                bind(stmt, i, escapeLikePrefix(prefix) + "%")
                i += 1
            }
            sqlite3_bind_int(stmt, i, Int32(capped))
            var out: [MemoryNote] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let note = mapMemoryNote(stmt)
                if let tag, !note.tags.contains(tag) { continue }
                out.append(note)
            }
            return out
        }
    }

    /// Case-insensitive substring search over key, body, and tags_json.
    public func memorySearch(
        query: String,
        includeSystem: Bool = false,
        limit: Int = SQLiteStore.memoryQueryDefaultLimit
    ) throws -> [MemoryNote] {
        let capped = min(max(limit, 1), Self.memoryQueryMaxLimit)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var sql = """
        SELECT key, body, tags_json, created_at, updated_at
        FROM memory_notes
        WHERE (key LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR tags_json LIKE ? ESCAPE '\\')
        """
        if !includeSystem {
            sql += " AND key NOT LIKE 'agent\\_run/%' ESCAPE '\\' AND key NOT LIKE 'agent\\_active/%' ESCAPE '\\'"
        }
        sql += " ORDER BY updated_at DESC LIMIT ?"

        let pattern = "%" + escapeLikePrefix(needle) + "%"
        return try withStatement(sql) { stmt in
            bind(stmt, 1, pattern)
            bind(stmt, 2, pattern)
            bind(stmt, 3, pattern)
            sqlite3_bind_int(stmt, 4, Int32(capped))
            var out: [MemoryNote] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(mapMemoryNote(stmt))
            }
            return out
        }
    }

    public func memoryCount(includeSystem: Bool = false) throws -> Int {
        var sql = "SELECT COUNT(*) FROM memory_notes WHERE 1=1"
        if !includeSystem {
            sql += " AND key NOT LIKE 'agent\\_run/%' ESCAPE '\\' AND key NOT LIKE 'agent\\_active/%' ESCAPE '\\'"
        }
        return try queryInt(sql) ?? 0
    }

    private func mapMemoryNote(_ stmt: OpaquePointer) -> MemoryNote {
        let key = String(cString: sqlite3_column_text(stmt, 0))
        let body = String(cString: sqlite3_column_text(stmt, 1))
        let tagsJSON = textCol(stmt, 2) ?? "[]"
        let created = textCol(stmt, 3) ?? ""
        let updated = textCol(stmt, 4) ?? ""
        let tags = Self.decodeTags(tagsJSON)
        return MemoryNote(key: key, body: body, tags: tags, createdAt: created, updatedAt: updated)
    }

    private static func decodeTags(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr
    }

    /// Escape `%` and `_` for SQLite LIKE with ESCAPE '\\'.
    private func escapeLikePrefix(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Audit

    public func auditAppend(_ event: AuditEvent) throws {
        let ts = ISO8601.string(from: event.timestamp)
        try withStatement(
            """
            INSERT INTO audit_events(timestamp, client_id, tool, args_digest, args_json, status, duration_ms, error)
            VALUES(?,?,?,?,?,?,?,?)
            """
        ) { stmt in
            bind(stmt, 1, ts)
            bind(stmt, 2, event.clientID)
            bind(stmt, 3, event.tool)
            bind(stmt, 4, event.argsDigest)
            bind(stmt, 5, event.argsJSON)
            bind(stmt, 6, event.status)
            if let ms = event.durationMs {
                sqlite3_bind_int(stmt, 7, Int32(ms))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            bind(stmt, 8, event.error)
            try stepDone(stmt)
        }
    }

    public func auditRecent(limit: Int = 50) throws -> [AuditEvent] {
        try withStatement(
            """
            SELECT timestamp, client_id, tool, args_digest, args_json, status, duration_ms, error
            FROM audit_events ORDER BY id DESC LIMIT ?
            """
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [AuditEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = String(cString: sqlite3_column_text(stmt, 0))
                let client: String? = textCol(stmt, 1)
                let tool = String(cString: sqlite3_column_text(stmt, 2))
                let digest = textCol(stmt, 3)
                let args = textCol(stmt, 4)
                let status = textCol(stmt, 5) ?? "ok"
                let ms: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
                let err = textCol(stmt, 7)
                out.append(AuditEvent(
                    timestamp: ISO8601.date(from: ts) ?? Date(),
                    clientID: client,
                    tool: tool,
                    argsDigest: digest,
                    argsJSON: args,
                    status: status,
                    durationMs: ms,
                    error: err
                ))
            }
            return out
        }
    }

    // MARK: - Presence

    public func presenceUpsert(clientID: String, hostKind: String, pid: Int32, cwd: String) throws {
        let ts = ISO8601.string(from: clock.now())
        try withStatement(
            """
            INSERT INTO presence(client_id, host_kind, pid, cwd, last_heartbeat)
            VALUES(?,?,?,?,?)
            ON CONFLICT(client_id) DO UPDATE SET
              host_kind=excluded.host_kind, pid=excluded.pid, cwd=excluded.cwd, last_heartbeat=excluded.last_heartbeat
            """
        ) { stmt in
            bind(stmt, 1, clientID)
            bind(stmt, 2, hostKind)
            sqlite3_bind_int(stmt, 3, pid)
            bind(stmt, 4, cwd)
            bind(stmt, 5, ts)
            try stepDone(stmt)
        }
    }

    public func presenceRecords() throws -> [PresenceRecord] {
        try withStatement(
            "SELECT client_id, host_kind, pid, cwd, last_heartbeat FROM presence ORDER BY last_heartbeat DESC"
        ) { stmt in
            var out: [PresenceRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(PresenceRecord(
                    clientID: String(cString: sqlite3_column_text(stmt, 0)),
                    hostKind: textCol(stmt, 1) ?? "",
                    pid: sqlite3_column_int(stmt, 2),
                    cwd: textCol(stmt, 3) ?? "",
                    lastHeartbeat: textCol(stmt, 4) ?? ""
                ))
            }
            return out
        }
    }

    /// Edge adapter for HTTP / legacy callers.
    public func presenceList() throws -> [[String: Any]] {
        try presenceRecords().map { $0.asDictionary() }
    }

    public func presenceDelete(clientID: String) throws {
        try withStatement("DELETE FROM presence WHERE client_id = ?") { stmt in
            bind(stmt, 1, clientID)
            try stepDone(stmt)
        }
    }

    /// Remove presence rows whose process is gone or heartbeat is older than `maxAgeSec`.
    @discardableResult
    public func presencePrune(maxAgeSec: TimeInterval = 120) throws -> Int {
        let rows = try presenceRecords()
        var removed = 0
        let now = clock.now()
        for row in rows {
            let clientID = row.clientID
            guard !clientID.isEmpty else { continue }
            let pid = row.pid
            let hb = row.lastHeartbeat
            let age: TimeInterval?
            if let d = ISO8601.date(from: hb) {
                age = now.timeIntervalSince(d)
            } else {
                age = nil
            }
            let processDead = pid <= 0 || kill(pid, 0) != 0
            let stale = age == nil || (age ?? 0) > maxAgeSec
            if processDead && stale {
                try presenceDelete(clientID: clientID)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw StoreError.openFailed("nil db") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.execFailed(msg)
        }
    }

    private func changes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    private func queryInt(_ sql: String) throws -> Int? {
        try withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw StoreError.openFailed("nil db") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt else { throw StoreError.execFailed("nil statement") }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let value {
            value.withCString { cstr in
                _ = sqlite3_bind_text(stmt, idx, cstr, -1, Self.sqliteTransient)
            }
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func textCol(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func mapSession(_ stmt: OpaquePointer) -> AgentSession {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let agent = String(cString: sqlite3_column_text(stmt, 1))
        let client = textCol(stmt, 2).map { ClientID($0) }
        let status = SessionStatus(rawValue: textCol(stmt, 3) ?? "closed") ?? .closed
        let summary = textCol(stmt, 4)
        let created = textCol(stmt, 5).flatMap(ISO8601.date(from:)) ?? Date()
        let updated = textCol(stmt, 6).flatMap(ISO8601.date(from:)) ?? Date()
        return AgentSession(
            id: SessionID(id),
            agentID: agent,
            clientID: client,
            status: status,
            summary: summary,
            createdAt: created,
            updatedAt: updated
        )
    }
}
