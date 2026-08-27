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
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let s): "SQLite open failed: \(s)"
        case .execFailed(let s): "SQLite error: \(s)"
        case .notFound(let s): s
        case .conflict(let s): s
        }
    }
}

/// Per-operation SQLite control installed while a cancellable call owns the
/// shared connection. SQLite invokes these callbacks synchronously, so the
/// control remains alive for exactly the duration of `withSQLiteControlUnlocked`.
private final class SQLiteStoreOperationControl {
    private static let defaultBusyLimitSeconds: TimeInterval = 3
    private static let busyPollSeconds: TimeInterval = 0.01

    let cancellation: ToolCallCancellation?
    private let busyRetryObserver: (@Sendable () -> Void)?
    private let busyDeadlineUptimeNanoseconds: UInt64
    private var reportedBusy = false

    init(
        cancellation: ToolCallCancellation?,
        busyRetryObserver: (@Sendable () -> Void)?,
        maximumBusyWaitSeconds: TimeInterval = defaultBusyLimitSeconds
    ) {
        self.cancellation = cancellation
        self.busyRetryObserver = busyRetryObserver
        let boundedSeconds = min(max(maximumBusyWaitSeconds, 0), Self.defaultBusyLimitSeconds)
        let busyLimitNanoseconds = UInt64((boundedSeconds * 1_000_000_000).rounded(.up))
        busyDeadlineUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(busyLimitNanoseconds).partialValue
    }

    func checkCancellation() throws {
        try cancellation?.checkCancellation()
    }

    func checkBusyBudget() throws {
        try checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < busyDeadlineUptimeNanoseconds else {
            throw StoreError.execFailed("database is busy")
        }
    }

    func shouldInterrupt() -> Bool {
        cancellation?.isCancelled == true || cancellation?.isDeadlineExceeded == true
    }

    func waitForBusyRetry() -> Int32 {
        if !reportedBusy {
            reportedBusy = true
            busyRetryObserver?()
        }
        guard !shouldInterrupt() else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < busyDeadlineUptimeNanoseconds else { return 0 }
        let fallbackRemaining = TimeInterval(busyDeadlineUptimeNanoseconds - now) / 1_000_000_000
        let requestedRemaining = cancellation?.remainingTimeInterval ?? fallbackRemaining
        let delay = min(Self.busyPollSeconds, fallbackRemaining, requestedRemaining)
        guard delay > 0 else { return 0 }
        Thread.sleep(forTimeInterval: delay)
        return shouldInterrupt() || DispatchTime.now().uptimeNanoseconds >= busyDeadlineUptimeNanoseconds
            ? 0
            : 1
    }
}

private func sqliteStoreBusyHandler(
    _ context: UnsafeMutableRawPointer?,
    _ priorAttempts: Int32
) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<SQLiteStoreOperationControl>.fromOpaque(context)
        .takeUnretainedValue()
        .waitForBusyRetry()
}

private func sqliteStoreProgressHandler(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<SQLiteStoreOperationControl>.fromOpaque(context)
        .takeUnretainedValue()
        .shouldInterrupt() ? 1 : 0
}

enum SQLiteStoreMutationKind: String, Sendable {
    case audit
    case handoff
    case memory
    case presence
    case session
}

/// SQLite3-backed store using the system library.
public final class SQLiteStore: PresenceStore, SessionStore, AuditReading, @unchecked Sendable {
    static let schemaVersion = 6
    private static let maximumHandoffQueryRows = 10_000
    private static let maximumPresenceQueryRows = 10_000
    private static let maximumSessionQueryRows = 10_000
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var openRegistration: SQLiteOpenRegistration?
    private var countedAsOpen = false
    public let path: URL
    private let clock: any Clock
    private let beforeMigrationCommitObserver: (@Sendable () throws -> Void)?
    private let postMigrationCommitObserver: (
        @Sendable (VerifiedMigrationBackupManifest) throws -> Void
    )?
    private let sqliteBusyRetryObserver: (@Sendable () -> Void)?
    private let beforeMutationCommitObserver: (@Sendable (SQLiteStoreMutationKind) throws -> Void)?
    private let didMutationCommitObserver: (@Sendable (SQLiteStoreMutationKind) -> Void)?

    /// SQLite copies the bound text; required so Swift string buffers can free.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public convenience init(path: URL, clock: any Clock = SystemClock()) throws {
        try self.init(
            path: path,
            clock: clock,
            beforeMigrationCommitObserver: nil,
            postMigrationCommitObserver: nil,
            sqliteBusyRetryObserver: nil,
            beforeMutationCommitObserver: nil,
            didMutationCommitObserver: nil
        )
    }

    init(
        path: URL,
        clock: any Clock = SystemClock(),
        beforeMigrationCommitObserver: (@Sendable () throws -> Void)? = nil,
        postMigrationCommitObserver: (
            @Sendable (VerifiedMigrationBackupManifest) throws -> Void
        )?,
        sqliteBusyRetryObserver: (@Sendable () -> Void)? = nil,
        beforeMutationCommitObserver: (@Sendable (SQLiteStoreMutationKind) throws -> Void)? = nil,
        didMutationCommitObserver: (@Sendable (SQLiteStoreMutationKind) -> Void)? = nil
    ) throws {
        self.path = path
        self.clock = clock
        self.beforeMigrationCommitObserver = beforeMigrationCommitObserver
        self.postMigrationCommitObserver = postMigrationCommitObserver
        self.sqliteBusyRetryObserver = sqliteBusyRetryObserver
        self.beforeMutationCommitObserver = beforeMutationCommitObserver
        self.didMutationCommitObserver = didMutationCommitObserver
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var migrationManifest: VerifiedMigrationBackupManifest?
        try VerifiedMigrationBackup.withMigrationLock(databaseURL: path, timeoutSeconds: 60) {
            do {
                try VerifiedMigrationBackup.withNonMutatingSQLitePreflight(
                    databaseURL: path
                ) { candidate in
                    guard let candidate else {
                        _ = try VerifiedMigrationBackup.reconcileMigrationManifest(
                            sourceURL: path,
                            observedVersion: 0
                        )
                        return
                    }
                    let hasVersionTable = try candidate.integer(
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
                    ) == 1
                    guard hasVersionTable else {
                        try candidate.requireEmptySchemaWhenUnversioned(reportedVersion: 0)
                        _ = try VerifiedMigrationBackup.reconcileMigrationManifest(
                            sourceURL: path,
                            observedVersion: 0
                        )
                        return
                    }
                    let rowCount = try candidate.integer("SELECT COUNT(*) FROM schema_version") ?? 0
                    let version = try candidate.integer(
                        "SELECT version FROM schema_version LIMIT 1"
                    ) ?? 0
                    guard rowCount == 1, (1...Self.schemaVersion).contains(version) else {
                        throw VerifiedMigrationBackupError.invalidSource(
                            "unsupported or malformed SQLite schema version \(version)"
                        )
                    }
                    migrationManifest = try VerifiedMigrationBackup
                        .reconcileMigrationManifest(
                            sourceURL: path,
                            observedVersion: version
                        )
                }
            } catch {
                throw StoreError.openFailed(error.localizedDescription)
            }
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
                let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                if let handle { sqlite3_close(handle) }
                throw StoreError.openFailed(msg)
            }
            db = handle
            do {
                // GUI manager + MCP serve share one home. Without a busy timeout, a locked
                // store can stall serve startup long enough for LM Studio's ~60s plugin timeout.
                try exec("PRAGMA busy_timeout=3000;")
                try validateSchemaBeforeWrite()
                if migrationManifest == nil {
                    migrationManifest = try currentMigrationManifest()
                }
                try exec("PRAGMA journal_mode=WAL;")
                try exec("PRAGMA foreign_keys=ON;")
                try migrateLocked(migrationManifest: migrationManifest)
                openRegistration = try VerifiedMigrationBackup.registerOpenDatabase(at: path)
            } catch {
                sqlite3_close(handle)
                db = nil
                throw error
            }
        }
        countedAsOpen = true
        RuntimeDiagnostics.shared.adjust(.openDatabases, by: 1)
        recordDatabaseFootprint()
    }

    private func validateSchemaBeforeWrite() throws {
        lock.lock()
        defer { lock.unlock() }
        let hasVersionTable = try queryIntUnlocked(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
        ) == 1
        guard let db else { throw StoreError.openFailed("nil db") }
        do {
            if hasVersionTable {
                let rowCount = try queryIntUnlocked("SELECT COUNT(*) FROM schema_version") ?? 0
                let prior = try queryIntUnlocked("SELECT version FROM schema_version LIMIT 1") ?? 0
                guard rowCount == 1, (1...Self.schemaVersion).contains(prior) else {
                    throw VerifiedMigrationBackupError.invalidSource(
                        "unsupported or malformed SQLite schema version \(prior)"
                    )
                }
                return
            }
            try VerifiedMigrationBackup.requireEmptySQLiteSchemaWhenUnversioned(
                database: db,
                reportedVersion: 0
            )
        } catch {
            throw StoreError.openFailed(error.localizedDescription)
        }
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
            VerifiedMigrationBackup.unregisterOpenDatabase(openRegistration)
            openRegistration = nil
            if countedAsOpen {
                countedAsOpen = false
                RuntimeDiagnostics.shared.adjust(.openDatabases, by: -1)
            }
        }
    }

    // MARK: - Schema

    public func migrate() throws {
        try VerifiedMigrationBackup.withMigrationLock(databaseURL: path, timeoutSeconds: 60) {
            let manifest = try currentMigrationManifest()
            try migrateLocked(migrationManifest: manifest)
        }
    }

    private func migrateLocked(
        migrationManifest initialManifest: VerifiedMigrationBackupManifest?
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw StoreError.openFailed("nil db") }
        let hasVersionTable = try queryIntUnlocked(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
        ) == 1
        let prior = hasVersionTable
            ? try queryIntUnlocked("SELECT version FROM schema_version LIMIT 1") ?? 0
            : 0
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

        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            if isSchemaMigration {
                migrationManifest = try VerifiedMigrationBackup
                    .prepareSQLiteMigrationAtWriteBoundary(
                        database: db,
                        sourceURL: path,
                        backupURL: migrationBackupURL(sourceVersion: prior),
                        sourceVersion: prior,
                        targetVersion: Self.schemaVersion,
                        versionQuery: "SELECT version FROM schema_version LIMIT 1"
                    )
            } else if prior == Self.schemaVersion, let currentManifest = migrationManifest {
                migrationManifest = try VerifiedMigrationBackup.requireSQLiteMigrationReceipt(
                    database: db,
                    sourceURL: path,
                    manifest: currentManifest
                )
            }
            try migrateUnlockedDatabase()
            if isSchemaMigration, let migrationManifest {
                try VerifiedMigrationBackup.recordSQLiteMigrationReceipt(
                    database: db,
                    sourceURL: path,
                    manifest: migrationManifest
                )
            }
            if needsDurableCompletion {
                try beforeMigrationCommitObserver?()
                try VerifiedMigrationBackup.requireSQLiteMainFileUnmoved(
                    database: db,
                    sourceURL: path,
                    purpose: "SQLite store migration commit"
                )
            }
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }

        if isSchemaMigration, let migrationManifest {
            try postMigrationCommitObserver?(migrationManifest)
        }
        if let migrationManifest, migrationManifest.state == .prepared {
            try VerifiedMigrationBackup.checkpointSQLiteMigration(
                database: db,
                sourceURL: path
            )
            let observedVersion = try queryIntUnlocked(
                "SELECT version FROM schema_version LIMIT 1"
            ) ?? 0
            let target = try VerifiedMigrationBackup.logicalSQLiteMetadata(
                database: db,
                sourceURL: path,
                expectedVersion: Self.schemaVersion,
                versionQuery: "SELECT version FROM schema_version LIMIT 1"
            )
            _ = try VerifiedMigrationBackup.completeMigrationManifest(
                sourceURL: path,
                preparedManifest: migrationManifest,
                observedVersion: observedVersion,
                targetMetadata: target
            )
        }
    }

    private func currentMigrationManifest() throws -> VerifiedMigrationBackupManifest? {
        lock.lock()
        defer { lock.unlock() }
        let hasVersionTable = try queryIntUnlocked(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
        ) == 1
        guard hasVersionTable else {
            return try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: path,
                observedVersion: 0
            )
        }
        let prior = try queryIntUnlocked("SELECT version FROM schema_version LIMIT 1") ?? 0
        return try VerifiedMigrationBackup.reconcileMigrationManifest(
            sourceURL: path,
            observedVersion: prior
        )
    }

    private func migrationBackupURL(sourceVersion: Int) -> URL {
        let stem = path.deletingPathExtension().lastPathComponent
        return path.deletingLastPathComponent().appendingPathComponent(
            "\(stem).pre-migration-v\(sourceVersion).sqlite3",
            isDirectory: false
        )
    }

    private func migrateUnlockedDatabase() throws {
        try execUnlocked("""
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
        CREATE TABLE IF NOT EXISTS context_handoffs (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            source TEXT NOT NULL,
            resume_ready INTEGER NOT NULL DEFAULT 0,
            packet_json TEXT NOT NULL,
            client_id TEXT,
            write_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_context_handoffs_updated
            ON context_handoffs(updated_at DESC);
        """)
        if try !tableHasColumnUnlocked(table: "context_handoffs", column: "write_sequence") {
            try execUnlocked(
                "ALTER TABLE context_handoffs ADD COLUMN write_sequence INTEGER NOT NULL DEFAULT 0;"
            )
        }
        if try !tableHasColumnUnlocked(table: "context_handoffs", column: "client_id") {
            try execUnlocked("ALTER TABLE context_handoffs ADD COLUMN client_id TEXT;")
        }
        try execUnlocked("""
        UPDATE context_handoffs
        SET write_sequence = rowid
        WHERE write_sequence = 0;
        CREATE INDEX IF NOT EXISTS idx_context_handoffs_sequence
            ON context_handoffs(write_sequence DESC);
        CREATE INDEX IF NOT EXISTS idx_context_handoffs_client_sequence
            ON context_handoffs(client_id, write_sequence DESC);
        """)
        let supersededSummary = try JSONSupport.string(from: [
            "event": "migration_superseded_duplicate",
            "ok_to_reuse": true,
            "message": "Closed while enforcing one open agent session per client",
        ])
        let migrationTimestamp = ISO8601.string(from: clock.now())
        try reconcileOpenAgentSessionsForUniqueIndexUnlocked(
            supersededSummary: supersededSummary,
            timestamp: migrationTimestamp
        )
        try execUnlocked("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_sessions_one_open_per_client
            ON agent_sessions(client_id)
            WHERE client_id IS NOT NULL
              AND status IN ('open','active','running','started');
        """)
        let version: Int = try queryIntUnlocked("SELECT version FROM schema_version LIMIT 1") ?? 0
        if version == 0 {
            try execUnlocked(
                "INSERT INTO schema_version(version) VALUES (\(Self.schemaVersion));"
            )
        } else if version < Self.schemaVersion {
            try execUnlocked(
                "UPDATE schema_version SET version = \(Self.schemaVersion);"
            )
        }
    }

    private func reconcileOpenAgentSessionsForUniqueIndexUnlocked(
        supersededSummary: String,
        timestamp: String
    ) throws {
        let openCount = try queryIntUnlocked(
            """
            SELECT COUNT(*) FROM agent_sessions
            WHERE client_id IS NOT NULL
              AND status IN ('open','active','running','started')
            """
        ) ?? 0
        guard openCount <= Self.maximumSessionQueryRows else {
            throw StoreError.conflict(
                "Too many legacy open agent sessions to reconcile safely"
            )
        }
        let openSessions = try withStatementUnlocked(
            """
            SELECT id,agent_id,client_id,status,summary,created_at,updated_at
            FROM agent_sessions
            WHERE client_id IS NOT NULL
              AND status IN ('open','active','running','started')
            ORDER BY updated_at DESC, created_at DESC, id DESC
            """
        ) { statement in
            var sessions: [AgentSession] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                sessions.append(mapSession(statement))
            }
            return sessions
        }
        let sessionsByClient = Dictionary(grouping: openSessions) {
            $0.clientID?.rawValue ?? ""
        }

        let bindingCount = try queryIntUnlocked(
            "SELECT COUNT(*) FROM memory_notes WHERE key GLOB 'agent_active/*'"
        ) ?? 0
        guard bindingCount <= Self.maximumSessionQueryRows else {
            throw StoreError.conflict(
                "Too many legacy agent bindings to reconcile safely"
            )
        }
        let bindingNotes = try withStatementUnlocked(
            """
            SELECT key,body,tags_json,created_at,updated_at
            FROM memory_notes WHERE key GLOB 'agent_active/*'
            ORDER BY key
            """
        ) { statement in
            var notes: [MemoryNote] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                notes.append(mapMemoryNote(statement))
            }
            return notes
        }
        var validPointedSessionByClient: [String: SessionID] = [:]
        for note in bindingNotes {
            let client = String(note.key.dropFirst("agent_active/".count))
            let pointedSession = try agentBindingSessionID(from: note.body)
            let valid = sessionsByClient[client]?.contains {
                $0.id == pointedSession && $0.clientID?.rawValue == client
            } == true
            if valid, let pointedSession {
                validPointedSessionByClient[client] = pointedSession
            } else {
                try withStatementUnlocked(
                    "DELETE FROM memory_notes WHERE key=? AND body=?"
                ) { statement in
                    bind(statement, 1, note.key)
                    bind(statement, 2, note.body)
                    try stepDone(statement)
                }
            }
        }

        for (client, sessions) in sessionsByClient where sessions.count > 1 {
            let survivorID = validPointedSessionByClient[client] ?? sessions[0].id
            for session in sessions where session.id != survivorID {
                try withStatementUnlocked(
                    """
                    UPDATE agent_sessions
                    SET status='closed', summary=COALESCE(summary, ?), updated_at=?
                    WHERE id=? AND status IN ('open','active','running','started')
                    """
                ) { statement in
                    bind(statement, 1, supersededSummary)
                    bind(statement, 2, timestamp)
                    bind(statement, 3, session.id.rawValue)
                    try stepDone(statement)
                }
            }
        }

        // A stale or missing projection can be rebuilt without inventing policy:
        // the surviving row durably owns both the session and agent identifiers,
        // while AgentSessionService rehydrates optional policy fields from the
        // catalog. Keep a valid existing projection byte-for-byte.
        for (client, sessions) in sessionsByClient
        where validPointedSessionByClient[client] == nil {
            guard let survivor = sessions.first else { continue }
            let body = try JSONSupport.string(from: [
                "session_id": survivor.id.rawValue,
                "agent_id": survivor.agentID,
            ])
            try memorySetUnlocked(
                key: "agent_active/\(client)",
                body: body,
                tags: ["agent_active", survivor.agentID],
                timestamp: timestamp
            )
        }
    }

    // MARK: - Context handoffs

    public func handoffUpsert(
        _ packet: HandoffPacket,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try cancellation?.checkCancellation()
        let json = try JSONSupport.string(from: packet.asDictionary())
        let noteTimestamp = ISO8601.string(from: clock.now())
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .handoff) {
                try cancellation?.checkCancellation()
                try withStatementUnlocked(
                    """
                    INSERT INTO context_handoffs(
                        id, created_at, updated_at, source, resume_ready, packet_json, client_id, write_sequence
                    )
                    SELECT ?, ?, ?, ?, ?, ?, ?, COALESCE(MAX(write_sequence), 0) + 1
                    FROM context_handoffs
                    WHERE true
                    ON CONFLICT(id) DO UPDATE SET
                        updated_at=excluded.updated_at,
                        source=excluded.source,
                        resume_ready=excluded.resume_ready,
                        packet_json=excluded.packet_json,
                        client_id=excluded.client_id,
                        write_sequence=excluded.write_sequence
                    """
                ) { stmt in
                    bind(stmt, 1, packet.id)
                    bind(stmt, 2, packet.createdAt)
                    bind(stmt, 3, packet.updatedAt)
                    bind(stmt, 4, packet.source.rawValue)
                    sqlite3_bind_int(stmt, 5, packet.resumeReady ? 1 : 0)
                    bind(stmt, 6, json)
                    bind(stmt, 7, packet.clientID)
                    try stepDone(stmt)
                }
                try memorySetUnlocked(
                    key: "continuity/latest",
                    body: packet.id,
                    tags: ["continuity", "latest"],
                    timestamp: noteTimestamp
                )
                if packet.resumeReady {
                    try cancellation?.checkCancellation()
                    try memorySetUnlocked(
                        key: "continuity/resume_ready",
                        body: packet.id,
                        tags: ["continuity", "resume"],
                        timestamp: noteTimestamp
                    )
                }
            }
        }
    }

    public func handoffGet(
        id: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> HandoffPacket? {
        try withControlledStatement(
            "SELECT id, packet_json FROM context_handoffs WHERE id = ?",
            cancellation: cancellation
        ) { stmt in
            bind(stmt, 1, id)
            return try handoffPacketFromFirstRow(stmt, cancellation: cancellation)
        }
    }

    public func handoffLatest(
        resumeReadyOnly: Bool = false,
        clientID: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> HandoffPacket? {
        var predicates: [String] = []
        if resumeReadyOnly, predicates.count < 2 { predicates.append("resume_ready = 1") }
        if clientID != nil, predicates.count < 2 { predicates.append("client_id = ?") }
        let whereClause = predicates.isEmpty ? "" : " WHERE \(predicates.joined(separator: " AND "))"
        let sql = "SELECT id, packet_json FROM context_handoffs\(whereClause) ORDER BY write_sequence DESC LIMIT 1"
        return try withControlledStatement(sql, cancellation: cancellation) { stmt in
            if let clientID { bind(stmt, 1, clientID) }
            return try handoffPacketFromFirstRow(stmt, cancellation: cancellation)
        }
    }

    public func handoffList(
        limit: Int = 20,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [HandoffPacket] {
        let lim = max(1, min(limit, 100))
        return try handoffList(
            sql: "SELECT id, packet_json FROM context_handoffs ORDER BY write_sequence DESC LIMIT \(lim)",
            cancellation: cancellation
        )
    }

    public func handoffListAll(cancellation: ToolCallCancellation? = nil) throws -> [HandoffPacket] {
        try handoffList(
            sql: "SELECT id, packet_json FROM context_handoffs ORDER BY write_sequence DESC LIMIT \(Self.maximumHandoffQueryRows)",
            cancellation: cancellation
        )
    }

    private func handoffList(
        sql: String,
        cancellation: ToolCallCancellation?
    ) throws -> [HandoffPacket] {
        try withControlledStatement(sql, cancellation: cancellation) { stmt in
            var out: [HandoffPacket] = []
            while true {
                try cancellation?.checkCancellation()
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                if out.count >= Self.maximumHandoffQueryRows { break }
                guard let rowID = textCol(stmt, 0),
                      let cstr = sqlite3_column_text(stmt, 1) else { continue }
                let text = String(cString: cstr)
                guard let data = text.data(using: .utf8),
                      let obj = try? JSONSupport.object(from: data),
                      let packet = HandoffPacket.fromDictionary(obj),
                      packet.id == rowID else { continue }
                out.append(packet)
            }
            return out
        }
    }

    /// Rebuilds pointer notes from authoritative handoff rows. Used at bootstrap
    /// after legacy migration or recovery from an interrupted older-version write.
    public func handoffRepairPointers(cancellation: ToolCallCancellation? = nil) throws {
        let timestamp = ISO8601.string(from: clock.now())
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .handoff) {
                try cancellation?.checkCancellation()
                let latestID = try handoffIDUnlocked(resumeReadyOnly: false)
                let resumeID = try handoffIDUnlocked(resumeReadyOnly: true)
                try replaceContinuityPointerUnlocked(
                    key: "continuity/latest",
                    id: latestID,
                    tags: ["continuity", "latest"],
                    timestamp: timestamp
                )
                try replaceContinuityPointerUnlocked(
                    key: "continuity/resume_ready",
                    id: resumeID,
                    tags: ["continuity", "resume"],
                    timestamp: timestamp
                )
            }
        }
    }

    private func handoffPacketFromFirstRow(
        _ statement: OpaquePointer,
        cancellation: ToolCallCancellation?
    ) throws -> HandoffPacket? {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteStepError(result) }
        try cancellation?.checkCancellation()
        guard let rowID = textCol(statement, 0),
              let cstr = sqlite3_column_text(statement, 1) else { return nil }
        let text = String(cString: cstr)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSupport.object(from: data),
              let packet = HandoffPacket.fromDictionary(object),
              packet.id == rowID else { return nil }
        return packet
    }

    private func handoffIDUnlocked(resumeReadyOnly: Bool) throws -> String? {
        let predicate = resumeReadyOnly ? " WHERE resume_ready = 1" : ""
        return try withStatementUnlocked(
            "SELECT id FROM context_handoffs\(predicate) ORDER BY write_sequence DESC LIMIT 1"
        ) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteStepError(result) }
            return textCol(statement, 0)
        }
    }

    private func replaceContinuityPointerUnlocked(
        key: String,
        id: String?,
        tags: [String],
        timestamp: String
    ) throws {
        if let id {
            try memorySetUnlocked(key: key, body: id, tags: tags, timestamp: timestamp)
            return
        }
        try withStatementUnlocked("DELETE FROM memory_notes WHERE key = ?") { statement in
            bind(statement, 1, key)
            try stepDone(statement)
        }
    }

    // MARK: - Sessions

    public func sessionStart(
        agentID: String,
        clientID: ClientID?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AgentSession {
        let now = clock.now()
        let session = AgentSession(
            agentID: agentID,
            clientID: clientID,
            status: .open,
            createdAt: now,
            updatedAt: now
        )
        let ts = ISO8601.string(from: now)
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                try cancellation?.checkCancellation()
                try withStatementUnlocked(
                    "INSERT INTO agent_sessions (id, agent_id, client_id, status, summary, created_at, updated_at) VALUES (?,?,?,?,NULL,?,?)"
                ) { stmt in
                    bind(stmt, 1, session.id.rawValue)
                    bind(stmt, 2, agentID)
                    bind(stmt, 3, clientID?.rawValue)
                    bind(stmt, 4, SessionStatus.open.rawValue)
                    bind(stmt, 5, ts)
                    bind(stmt, 6, ts)
                    try stepDone(stmt)
                }
                return session
            }
        }
    }

    /// Replaces a client's open session and its durable active-binding projection
    /// in one commit. The run note is part of the same transaction, so callers
    /// never observe a newly-open session without the metadata required to resume it.
    public func sessionStartReplacingOpen(
        session: AgentSession,
        supersedeSummary: String,
        bindingBody: String,
        runBody: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AgentSession {
        guard let clientID = session.clientID, session.status.isOpen else {
            throw StoreError.conflict(
                "Replacement agent session must be open and owned by a client"
            )
        }
        let timestamp = ISO8601.string(from: session.updatedAt)
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                try cancellation?.checkCancellation()
                try withStatementUnlocked(
                    """
                    UPDATE agent_sessions
                    SET status='closed', summary=?, updated_at=?
                    WHERE client_id=? AND status IN ('open','active','running','started')
                    """
                ) { statement in
                    bind(statement, 1, supersedeSummary)
                    bind(statement, 2, timestamp)
                    bind(statement, 3, clientID.rawValue)
                    try stepDone(statement)
                }

                try cancellation?.checkCancellation()
                try withStatementUnlocked(
                    """
                    INSERT INTO agent_sessions(
                        id, agent_id, client_id, status, summary, created_at, updated_at
                    ) VALUES(?,?,?,?,NULL,?,?)
                    """
                ) { statement in
                    bind(statement, 1, session.id.rawValue)
                    bind(statement, 2, session.agentID)
                    bind(statement, 3, clientID.rawValue)
                    bind(statement, 4, session.status.rawValue)
                    bind(statement, 5, ISO8601.string(from: session.createdAt))
                    bind(statement, 6, timestamp)
                    try stepDone(statement)
                }

                try cancellation?.checkCancellation()
                try memorySetUnlocked(
                    key: "agent_active/\(clientID.rawValue)",
                    body: bindingBody,
                    tags: ["agent_active", session.agentID],
                    timestamp: timestamp
                )
                try memorySetUnlocked(
                    key: "agent_run/\(session.id.rawValue)",
                    body: runBody,
                    tags: ["agent_run", session.agentID],
                    timestamp: timestamp
                )
                guard let persisted = try sessionGetUnlocked(id: session.id) else {
                    throw StoreError.execFailed("replacement agent session did not persist")
                }
                return persisted
            }
        }
    }

    public func sessionGet(
        id: SessionID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AgentSession? {
        try withLockedSQLiteOperation(
            cancellation: cancellation,
            checkAfterSuccess: true
        ) {
            try sessionGetUnlocked(id: id)
        }
    }

    private func sessionGetUnlocked(id: SessionID) throws -> AgentSession? {
        try withStatementUnlocked(
            "SELECT id, agent_id, client_id, status, summary, created_at, updated_at FROM agent_sessions WHERE id = ?"
        ) { stmt in
            bind(stmt, 1, id.rawValue)
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteStepError(result) }
            return mapSession(stmt)
        }
    }

    func sessionOpen(
        for clientID: ClientID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AgentSession? {
        try withLockedSQLiteOperation(
            cancellation: cancellation,
            checkAfterSuccess: true
        ) {
            try withStatementUnlocked(
                """
                SELECT id,agent_id,client_id,status,summary,created_at,updated_at
                FROM agent_sessions
                WHERE client_id=? AND status IN ('open','active','running','started')
                ORDER BY updated_at DESC, created_at DESC, id DESC
                LIMIT 1
                """
            ) { statement in
                bind(statement, 1, clientID.rawValue)
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                return mapSession(statement)
            }
        }
    }

    func agentBindingMatches(
        clientID: ClientID,
        sessionID: SessionID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        try withLockedSQLiteOperation(
            cancellation: cancellation,
            checkAfterSuccess: true
        ) {
            try agentBindingMatchesUnlocked(clientID: clientID, sessionID: sessionID)
        }
    }

    @discardableResult
    func agentBindingDeleteIfMatches(
        clientID: ClientID,
        sessionID: SessionID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                guard try agentBindingSessionIDUnlocked(clientID: clientID) == sessionID else {
                    return false
                }
                try cancellation?.checkCancellation()
                return try deleteAgentBindingUnlocked(clientID: clientID)
            }
        }
    }

    @discardableResult
    func agentBindingDeleteIfUnchanged(
        clientID: ClientID,
        expectedBody: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                guard try memoryGetNoteUnlocked(
                    key: "agent_active/\(clientID.rawValue)"
                )?.body == expectedBody else {
                    return false
                }
                try cancellation?.checkCancellation()
                return try deleteAgentBindingUnlocked(clientID: clientID)
            }
        }
    }

    @discardableResult
    func sessionInstallBindingIfUnchanged(
        sessionID: SessionID,
        clientID: ClientID,
        expectedCurrentSessionID: SessionID?,
        bindingBody: String,
        agentID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        let timestamp = ISO8601.string(from: clock.now())
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                guard let session = try sessionGetUnlocked(id: sessionID),
                      session.status.isOpen,
                      session.clientID == clientID else {
                    return false
                }
                let note = try memoryGetNoteUnlocked(
                    key: "agent_active/\(clientID.rawValue)"
                )
                if let expectedCurrentSessionID {
                    guard try agentBindingSessionID(from: note?.body) == expectedCurrentSessionID else {
                        return false
                    }
                } else {
                    guard note == nil else { return false }
                }
                try cancellation?.checkCancellation()
                try memorySetUnlocked(
                    key: "agent_active/\(clientID.rawValue)",
                    body: bindingBody,
                    tags: ["agent_active", agentID],
                    timestamp: timestamp
                )
                return true
            }
        }
    }

    private func agentBindingMatchesUnlocked(
        clientID: ClientID,
        sessionID: SessionID
    ) throws -> Bool {
        guard try agentBindingSessionIDUnlocked(clientID: clientID) == sessionID,
              let session = try sessionGetUnlocked(id: sessionID) else {
            return false
        }
        return session.status.isOpen && session.clientID == clientID
    }

    private func agentBindingSessionIDUnlocked(clientID: ClientID) throws -> SessionID? {
        let note = try memoryGetNoteUnlocked(key: "agent_active/\(clientID.rawValue)")
        return try agentBindingSessionID(from: note?.body)
    }

    private func agentBindingSessionID(from body: String?) throws -> SessionID? {
        guard let body,
              let data = body.data(using: .utf8),
              let object = try? JSONSupport.object(from: data),
              let rawValue = object["session_id"] as? String,
              !rawValue.isEmpty else {
            return nil
        }
        return SessionID(rawValue)
    }

    @discardableResult
    private func deleteAgentBindingUnlocked(clientID: ClientID) throws -> Bool {
        try withStatementUnlocked(
            "DELETE FROM memory_notes WHERE key=?"
        ) { statement in
            bind(statement, 1, "agent_active/\(clientID.rawValue)")
            try stepDone(statement)
            return changesUnlocked() > 0
        }
    }

    public func sessionReattach(
        id: SessionID,
        expectedClientID: ClientID?,
        clientID: ClientID,
        bindingBody: String,
        agentID: String,
        supersedeSummary: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AgentSession {
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                try cancellation?.checkCancellation()
                guard let existing = try sessionGetUnlocked(id: id) else {
                    throw StoreError.notFound("Unknown agent session: \(id.rawValue)")
                }
                guard existing.status.isOpen else {
                    throw StoreError.notFound("Agent session is not open: \(id.rawValue)")
                }
                guard existing.clientID == expectedClientID else {
                    throw StoreError.conflict(
                        "Agent session ownership changed while reattaching: \(id.rawValue)"
                    )
                }

                let timestamp = ISO8601.string(from: clock.now())
                try withStatementUnlocked(
                    """
                    UPDATE agent_sessions
                    SET status='closed', summary=?, updated_at=?
                    WHERE client_id=? AND id<>? AND status IN ('open','active','running','started')
                    """
                ) { statement in
                    bind(statement, 1, supersedeSummary)
                    bind(statement, 2, timestamp)
                    bind(statement, 3, clientID.rawValue)
                    bind(statement, 4, id.rawValue)
                    try stepDone(statement)
                }

                if existing.clientID != clientID {
                    try cancellation?.checkCancellation()
                    try withStatementUnlocked(
                        """
                        UPDATE agent_sessions SET client_id=?, updated_at=?
                        WHERE id=? AND status IN ('open','active','running','started')
                        """
                    ) { statement in
                        bind(statement, 1, clientID.rawValue)
                        bind(statement, 2, timestamp)
                        bind(statement, 3, id.rawValue)
                        try stepDone(statement)
                        guard changesUnlocked() == 1 else {
                            throw StoreError.conflict(
                                "Agent session changed while reattaching: \(id.rawValue)"
                            )
                        }
                    }
                }

                if let expectedClientID, expectedClientID != clientID {
                    try withStatementUnlocked("DELETE FROM memory_notes WHERE key = ?") { statement in
                        bind(statement, 1, "agent_active/\(expectedClientID.rawValue)")
                        try stepDone(statement)
                    }
                }
                try cancellation?.checkCancellation()
                try memorySetUnlocked(
                    key: "agent_active/\(clientID.rawValue)",
                    body: bindingBody,
                    tags: ["agent_active", agentID],
                    timestamp: timestamp
                )
                guard let attached = try sessionGetUnlocked(id: id) else {
                    throw StoreError.notFound("Agent session missing after attach: \(id.rawValue)")
                }
                return attached
            }
        }
    }

    public func sessionEnd(
        id: SessionID,
        summary: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AgentSession {
        let ts = ISO8601.string(from: clock.now())
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                guard try sessionGetUnlocked(id: id) != nil else {
                    throw StoreError.notFound("Unknown agent session: \(id.rawValue)")
                }
                try cancellation?.checkCancellation()
                try withStatementUnlocked(
                    "UPDATE agent_sessions SET status='closed', summary=?, updated_at=? WHERE id=?"
                ) { stmt in
                    bind(stmt, 1, summary)
                    bind(stmt, 2, ts)
                    bind(stmt, 3, id.rawValue)
                    try stepDone(stmt)
                }
                guard let session = try sessionGetUnlocked(id: id) else {
                    throw StoreError.notFound("session missing after end")
                }
                return session
            }
        }
    }

    /// Closes a session and removes its matching active-binding projection in
    /// the same commit. A newer binding for the same client is left untouched.
    public func sessionEndClearingBinding(
        id: SessionID,
        summary: String?,
        clientID: ClientID?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AgentSession {
        let timestamp = ISO8601.string(from: clock.now())
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                guard let current = try sessionGetUnlocked(id: id) else {
                    throw StoreError.notFound("Unknown agent session: \(id.rawValue)")
                }
                try cancellation?.checkCancellation()
                try withStatementUnlocked(
                    "UPDATE agent_sessions SET status='closed', summary=?, updated_at=? WHERE id=?"
                ) { statement in
                    bind(statement, 1, summary)
                    bind(statement, 2, timestamp)
                    bind(statement, 3, id.rawValue)
                    try stepDone(statement)
                }
                let bindingClients = [current.clientID, clientID]
                    .compactMap { $0 }
                    .reduce(into: [ClientID]()) { clients, candidate in
                        if !clients.contains(candidate) { clients.append(candidate) }
                    }
                for bindingClientID in bindingClients {
                    if try agentBindingSessionIDUnlocked(clientID: bindingClientID) == id {
                        try cancellation?.checkCancellation()
                        _ = try deleteAgentBindingUnlocked(clientID: bindingClientID)
                    }
                }
                guard let persisted = try sessionGetUnlocked(id: id) else {
                    throw StoreError.execFailed("closed agent session did not persist")
                }
                return persisted
            }
        }
    }

    public func sessionTouch(
        id: SessionID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        let ts = ISO8601.string(from: clock.now())
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                try cancellation?.checkCancellation()
                return try withStatementUnlocked(
                    """
                    UPDATE agent_sessions SET updated_at=?
                    WHERE id=? AND status IN ('open','active','running','started')
                    """
                ) { stmt in
                    bind(stmt, 1, ts)
                    bind(stmt, 2, id.rawValue)
                    try stepDone(stmt)
                    return changesUnlocked() > 0
                }
            }
        }
    }

    public func sessionList(agentID: String? = nil, status: SessionStatus? = nil) throws -> [AgentSession] {
        try sessionList(agentID: agentID, status: status, cancellation: nil)
    }

    public func sessionList(
        agentID: String? = nil,
        status: SessionStatus? = nil,
        cancellation: ToolCallCancellation?
    ) throws -> [AgentSession] {
        var sql = "SELECT id, agent_id, client_id, status, summary, created_at, updated_at FROM agent_sessions WHERE 1=1"
        if agentID != nil { sql += " AND agent_id = ?" }
        if status != nil { sql += " AND status = ?" }
        sql += " ORDER BY created_at DESC LIMIT \(Self.maximumSessionQueryRows)"
        return try withControlledStatement(sql, cancellation: cancellation) { stmt in
            var i: Int32 = 1
            if let agentID { bind(stmt, i, agentID); i += 1 }
            if let status { bind(stmt, i, status.rawValue); i += 1 }
            var out: [AgentSession] = []
            while true {
                try cancellation?.checkCancellation()
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                out.append(mapSession(stmt))
            }
            return out
        }
    }

    public func sessionCloseOpen(
        for clientID: ClientID,
        except: SessionID? = nil,
        summary: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [AgentSession] {
        let timestamp = ISO8601.string(from: clock.now())
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                var sql = """
                SELECT id,agent_id,client_id,status,summary,created_at,updated_at
                FROM agent_sessions
                WHERE client_id=? AND status IN ('open','active','running','started')
                """
                if except != nil { sql += " AND id<>?" }
                sql += " ORDER BY created_at DESC LIMIT \(Self.maximumSessionQueryRows)"
                let candidates = try withStatementUnlocked(sql) { statement in
                    bind(statement, 1, clientID.rawValue)
                    if let except { bind(statement, 2, except.rawValue) }
                    var values: [AgentSession] = []
                    while true {
                        try cancellation?.checkCancellation()
                        let result = sqlite3_step(statement)
                        if result == SQLITE_DONE { break }
                        guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                        values.append(mapSession(statement))
                    }
                    return values
                }
                guard !candidates.isEmpty else { return [] }
                try cancellation?.checkCancellation()
                for session in candidates {
                    try cancellation?.checkCancellation()
                    try withStatementUnlocked(
                        """
                        UPDATE agent_sessions SET status='closed',summary=?,updated_at=?
                        WHERE id=? AND status IN ('open','active','running','started')
                        """
                    ) { statement in
                        bind(statement, 1, summary)
                        bind(statement, 2, timestamp)
                        bind(statement, 3, session.id.rawValue)
                        try stepDone(statement)
                    }
                }
                var closed: [AgentSession] = []
                closed.reserveCapacity(candidates.count)
                for candidate in candidates {
                    guard let session = try sessionGetUnlocked(id: candidate.id) else {
                        throw StoreError.notFound("session missing after close")
                    }
                    closed.append(session)
                }
                return closed
            }
        }
    }

    /// Closes sessions that are still stale at the write boundary. Selection,
    /// cutoff verification, state transition, and matching binding cleanup share
    /// one transaction so a concurrent touch cannot be overwritten by cleanup.
    func sessionPruneStale(
        cutoff: Date,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [AgentSession] {
        let cutoffText = ISO8601.string(from: cutoff)
        let now = clock.now()
        let timestamp = ISO8601.string(from: now)
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .session) {
                let candidates = try withStatementUnlocked(
                    """
                    SELECT id,agent_id,client_id,status,summary,created_at,updated_at
                    FROM agent_sessions
                    WHERE status IN ('open','active','running','started') AND updated_at < ?
                    ORDER BY updated_at, created_at, id
                    LIMIT \(Self.maximumSessionQueryRows)
                    """
                ) { statement in
                    bind(statement, 1, cutoffText)
                    var sessions: [AgentSession] = []
                    while true {
                        try cancellation?.checkCancellation()
                        let result = sqlite3_step(statement)
                        if result == SQLITE_DONE { break }
                        guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                        sessions.append(mapSession(statement))
                    }
                    return sessions
                }

                var closed: [AgentSession] = []
                closed.reserveCapacity(candidates.count)
                for candidate in candidates {
                    try cancellation?.checkCancellation()
                    let age = max(0, Int(now.timeIntervalSince(candidate.updatedAt)))
                    let summary = try JSONSupport.string(from: [
                        "event": "auto_closed_stale",
                        "ok_to_reuse": true,
                        "age_sec": age,
                        "message": "Session abandoned without agent_run_complete (idle \(age)s).",
                    ])
                    let changed = try withStatementUnlocked(
                        """
                        UPDATE agent_sessions
                        SET status='closed', summary=?, updated_at=?
                        WHERE id=? AND updated_at < ?
                          AND status IN ('open','active','running','started')
                        """
                    ) { statement in
                        bind(statement, 1, summary)
                        bind(statement, 2, timestamp)
                        bind(statement, 3, candidate.id.rawValue)
                        bind(statement, 4, cutoffText)
                        try stepDone(statement)
                        return changesUnlocked() == 1
                    }
                    guard changed else { continue }
                    if let clientID = candidate.clientID,
                       try agentBindingSessionIDUnlocked(clientID: clientID) == candidate.id {
                        _ = try deleteAgentBindingUnlocked(clientID: clientID)
                    }
                    guard let persisted = try sessionGetUnlocked(id: candidate.id) else {
                        throw StoreError.execFailed("pruned agent session did not persist")
                    }
                    closed.append(persisted)
                }
                return closed
            }
        }
    }

    // MARK: - Memory notes

    /// Maximum key length accepted by MCP memory tools (UTF-8 bytes).
    public static let memoryKeyMaxBytes = 512
    /// Maximum body length accepted by MCP memory tools (UTF-8 bytes).
    public static let memoryBodyMaxBytes = 512 * 1024
    /// Soft cap on list/search result rows.
    public static let memoryQueryDefaultLimit = 50
    public static let memoryQueryMaxLimit = 200

    public func memorySet(
        key: String,
        body: String,
        tags: [String] = [],
        cancellation: ToolCallCancellation? = nil
    ) throws {
        _ = try memorySetAndGetNote(
            key: key,
            body: body,
            tags: tags,
            cancellation: cancellation
        )
    }

    /// Captures the authoritative row inside the write transaction. Once COMMIT
    /// succeeds, the result wins a concurrent cancellation because the durable
    /// side effect can no longer be rolled back.
    func memorySetAndGetNote(
        key: String,
        body: String,
        tags: [String] = [],
        cancellation: ToolCallCancellation? = nil
    ) throws -> MemoryNote {
        let timestamp = ISO8601.string(from: clock.now())
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(
                cancellation: cancellation,
                mutationKind: .memory
            ) {
                try cancellation?.checkCancellation()
                try memorySetUnlocked(
                    key: key,
                    body: body,
                    tags: tags,
                    timestamp: timestamp
                )
                guard let note = try memoryGetNoteUnlocked(key: key) else {
                    throw StoreError.execFailed("memory write did not persist")
                }
                return note
            }
        }
    }

    private func memorySetUnlocked(
        key: String,
        body: String,
        tags: [String],
        timestamp: String
    ) throws {
        let operation = DispatchTime.now().uptimeNanoseconds
        let signpost = RuntimeSignposts.memoryOperation(operation: operation)
        defer { RuntimeSignposts.memoryOperationEnded(signpost, operation: operation) }
        RuntimeDiagnostics.shared.increment(.memoryWrites)
        // store tags as JSON array string
        let tagsArr = try JSONSerialization.data(withJSONObject: tags)
        let tagsStr = String(data: tagsArr, encoding: .utf8) ?? "[]"
        try withStatementUnlocked(
            """
            INSERT INTO memory_notes(key, body, tags_json, created_at, updated_at)
            VALUES(?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET body=excluded.body, tags_json=excluded.tags_json, updated_at=excluded.updated_at
            """
        ) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, body)
            bind(stmt, 3, tagsStr)
            bind(stmt, 4, timestamp)
            bind(stmt, 5, timestamp)
            try stepDone(stmt)
        }
    }

    public func memoryGet(
        key: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> String? {
        try memoryGetNote(key: key, cancellation: cancellation)?.body
    }

    public func memoryGetNote(
        key: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> MemoryNote? {
        try withControlledStatement(
            "SELECT key, body, tags_json, created_at, updated_at FROM memory_notes WHERE key = ?",
            cancellation: cancellation
        ) { stmt in
            bind(stmt, 1, key)
            return try memoryNoteFromFirstRow(stmt)
        }
    }

    private func memoryGetNoteUnlocked(key: String) throws -> MemoryNote? {
        try withStatementUnlocked(
            "SELECT key, body, tags_json, created_at, updated_at FROM memory_notes WHERE key = ?"
        ) { stmt in
            bind(stmt, 1, key)
            return try memoryNoteFromFirstRow(stmt)
        }
    }

    public func memoryDelete(
        key: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(
                cancellation: cancellation,
                mutationKind: .memory
            ) {
                try cancellation?.checkCancellation()
                return try withStatementUnlocked("DELETE FROM memory_notes WHERE key = ?") { stmt in
                    bind(stmt, 1, key)
                    try stepDone(stmt)
                    return changesUnlocked() > 0
                }
            }
        }
    }

    /// List durable notes, newest updates first.
    /// - Parameters:
    ///   - prefix: Optional key prefix filter (e.g. `project/`).
    ///   - tag: Optional exact tag match (JSON array contains).
    ///   - includeSystem: When false (default), hides internal agent and continuity keys.
    ///   - limit: Max rows (clamped to `memoryQueryMaxLimit`).
    public func memoryList(
        prefix: String? = nil,
        tag: String? = nil,
        includeSystem: Bool = false,
        limit: Int = SQLiteStore.memoryQueryDefaultLimit,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [MemoryNote] {
        let capped = min(max(limit, 1), Self.memoryQueryMaxLimit)
        var sql = """
        SELECT key, body, tags_json, created_at, updated_at
        FROM memory_notes WHERE 1=1
        """
        if prefix != nil { sql += " AND key LIKE ? ESCAPE '\\'" }
        if !includeSystem {
            sql += " AND key NOT LIKE 'agent\\_run/%' ESCAPE '\\'"
            sql += " AND key NOT LIKE 'agent\\_active/%' ESCAPE '\\'"
            sql += " AND key NOT LIKE 'continuity/%' ESCAPE '\\'"
        }
        sql += " ORDER BY updated_at DESC LIMIT ?"

        return try withControlledStatement(sql, cancellation: cancellation) { stmt in
            var i: Int32 = 1
            if let prefix {
                bind(stmt, i, escapeLikePrefix(prefix) + "%")
                i += 1
            }
            sqlite3_bind_int(stmt, i, Int32(capped))
            var out: [MemoryNote] = []
            while true {
                try cancellation?.checkCancellation()
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
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
        limit: Int = SQLiteStore.memoryQueryDefaultLimit,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [MemoryNote] {
        try cancellation?.checkCancellation()
        let operation = DispatchTime.now().uptimeNanoseconds
        let signpost = RuntimeSignposts.memoryOperation(operation: operation)
        defer { RuntimeSignposts.memoryOperationEnded(signpost, operation: operation) }
        RuntimeDiagnostics.shared.increment(.memorySearches)
        let capped = min(max(limit, 1), Self.memoryQueryMaxLimit)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var sql = """
        SELECT key, body, tags_json, created_at, updated_at
        FROM memory_notes
        WHERE (key LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR tags_json LIKE ? ESCAPE '\\')
        """
        if !includeSystem {
            sql += " AND key NOT LIKE 'agent\\_run/%' ESCAPE '\\'"
            sql += " AND key NOT LIKE 'agent\\_active/%' ESCAPE '\\'"
            sql += " AND key NOT LIKE 'continuity/%' ESCAPE '\\'"
        }
        sql += " ORDER BY updated_at DESC LIMIT ?"

        let pattern = "%" + escapeLikePrefix(needle) + "%"
        return try withControlledStatement(sql, cancellation: cancellation) { stmt in
            bind(stmt, 1, pattern)
            bind(stmt, 2, pattern)
            bind(stmt, 3, pattern)
            sqlite3_bind_int(stmt, 4, Int32(capped))
            var out: [MemoryNote] = []
            while true {
                try cancellation?.checkCancellation()
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                out.append(mapMemoryNote(stmt))
            }
            return out
        }
    }

    public func memoryCount(
        includeSystem: Bool = false,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Int {
        var sql = "SELECT COUNT(*) FROM memory_notes WHERE 1=1"
        if !includeSystem {
            sql += " AND key NOT LIKE 'agent\\_run/%' ESCAPE '\\'"
            sql += " AND key NOT LIKE 'agent\\_active/%' ESCAPE '\\'"
            sql += " AND key NOT LIKE 'continuity/%' ESCAPE '\\'"
        }
        return try withControlledStatement(sql, cancellation: cancellation) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return 0 }
            guard result == SQLITE_ROW else { throw sqliteStepError(result) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func memoryNoteFromFirstRow(_ statement: OpaquePointer) throws -> MemoryNote? {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteStepError(result) }
        return mapMemoryNote(statement)
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

    private func recordDatabaseFootprint() {
        let manager = FileManager.default
        let databaseBytes = ((try? manager.attributesOfItem(atPath: path.path)[.size]) as? NSNumber)?.intValue ?? 0
        let walPath = path.path + "-wal"
        let walBytes = ((try? manager.attributesOfItem(atPath: walPath)[.size]) as? NSNumber)?.intValue ?? 0
        RuntimeDiagnostics.shared.set(.memoryDatabaseBytes, to: databaseBytes)
        RuntimeDiagnostics.shared.set(.memoryWALBytes, to: walBytes)
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

    public func auditAppend(
        _ event: AuditEvent,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        let ts = ISO8601.string(from: event.timestamp)
        try withLockedSQLiteOperation(
            cancellation: cancellation,
            maximumBusyWaitSeconds: 0.25
        ) {
            try transactionUnlocked(
                cancellation: cancellation,
                mutationKind: .audit
            ) {
                try cancellation?.checkCancellation()
                try withStatementUnlocked(
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
        try presenceUpsert(
            clientID: clientID,
            hostKind: hostKind,
            pid: pid,
            cwd: cwd,
            cancellation: nil
        )
    }

    public func presenceUpsert(
        clientID: String,
        hostKind: String,
        pid: Int32,
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws {
        let ts = ISO8601.string(from: clock.now())
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .presence) {
                try cancellation?.checkCancellation()
                try withStatementUnlocked(
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
        }
    }

    public func presenceRecords() throws -> [PresenceRecord] {
        try presenceRecords(cancellation: nil)
    }

    public func presenceRecords(
        cancellation: ToolCallCancellation?
    ) throws -> [PresenceRecord] {
        try withLockedSQLiteOperation(
            cancellation: cancellation,
            checkAfterSuccess: true
        ) {
            try presenceRecordsUnlocked(cancellation: cancellation)
        }
    }

    private func presenceRecordsUnlocked(
        cancellation: ToolCallCancellation?
    ) throws -> [PresenceRecord] {
        try withStatementUnlocked(
            """
            SELECT client_id,host_kind,pid,cwd,last_heartbeat
            FROM presence ORDER BY last_heartbeat DESC
            LIMIT \(Self.maximumPresenceQueryRows)
            """
        ) { statement in
            var records: [PresenceRecord] = []
            while true {
                try cancellation?.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                records.append(PresenceRecord(
                    clientID: String(cString: sqlite3_column_text(statement, 0)),
                    hostKind: textCol(statement, 1) ?? "",
                    pid: sqlite3_column_int(statement, 2),
                    cwd: textCol(statement, 3) ?? "",
                    lastHeartbeat: textCol(statement, 4) ?? ""
                ))
            }
            return records
        }
    }

    /// Edge adapter for HTTP / legacy callers.
    public func presenceList() throws -> [[String: Any]] {
        try presenceList(cancellation: nil)
    }

    public func presenceList(
        cancellation: ToolCallCancellation?
    ) throws -> [[String: Any]] {
        try presenceRecords(cancellation: cancellation).map { $0.asDictionary() }
    }

    public func presenceDelete(clientID: String) throws {
        try presenceDelete(clientID: clientID, cancellation: nil)
    }

    public func presenceDelete(
        clientID: String,
        cancellation: ToolCallCancellation?
    ) throws {
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .presence) {
                try cancellation?.checkCancellation()
                try withStatementUnlocked("DELETE FROM presence WHERE client_id = ?") { stmt in
                    bind(stmt, 1, clientID)
                    try stepDone(stmt)
                }
            }
        }
    }

    /// Remove presence rows whose process is gone or heartbeat is older than `maxAgeSec`.
    @discardableResult
    public func presencePrune(maxAgeSec: TimeInterval = 120) throws -> Int {
        try presencePrune(maxAgeSec: maxAgeSec, cancellation: nil)
    }

    @discardableResult
    public func presencePrune(
        maxAgeSec: TimeInterval = 120,
        cancellation: ToolCallCancellation?
    ) throws -> Int {
        try withLockedSQLiteOperation(cancellation: cancellation) {
            try transactionUnlocked(cancellation: cancellation, mutationKind: .presence) {
                let rows = try presenceRecordsUnlocked(cancellation: cancellation)
                let now = clock.now()
                var staleClientIDs: [String] = []
                for row in rows {
                    try cancellation?.checkCancellation()
                    let clientID = row.clientID
                    guard !clientID.isEmpty else { continue }
                    let age = ISO8601.date(from: row.lastHeartbeat)
                        .map { now.timeIntervalSince($0) }
                    let processDead = row.pid <= 0 || kill(row.pid, 0) != 0
                    let stale = age == nil || (age ?? 0) > maxAgeSec
                    if processDead && stale {
                        staleClientIDs.append(clientID)
                    }
                }
                for clientID in staleClientIDs {
                    try cancellation?.checkCancellation()
                    try withStatementUnlocked("DELETE FROM presence WHERE client_id = ?") { statement in
                        bind(statement, 1, clientID)
                        try stepDone(statement)
                    }
                }
                return staleClientIDs.count
            }
        }
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try execUnlocked(sql)
    }

    private func execUnlocked(_ sql: String) throws {
        guard let db else { throw StoreError.openFailed("nil db") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.execFailed(msg)
        }
    }

    private func changesUnlocked() -> Int {
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    private func queryInt(_ sql: String) throws -> Int? {
        try withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    private func queryIntUnlocked(_ sql: String) throws -> Int? {
        try withStatementUnlocked(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func tableHasColumnUnlocked(table: String, column: String) throws -> Bool {
        try withStatementUnlocked("PRAGMA table_info(\(table))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if textCol(stmt, 1) == column { return true }
            }
            return false
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withStatementUnlocked(sql, body: body)
    }

    private func withControlledStatement<T>(
        _ sql: String,
        cancellation: ToolCallCancellation?,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        try withLockedSQLiteOperation(
            cancellation: cancellation,
            checkAfterSuccess: true
        ) {
            try withStatementUnlocked(sql, body: body)
        }
    }

    private func withStatementUnlocked<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw StoreError.openFailed("nil db") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt else { throw StoreError.execFailed("nil statement") }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func transactionUnlocked<T>(
        cancellation: ToolCallCancellation?,
        mutationKind: SQLiteStoreMutationKind,
        _ body: () throws -> T
    ) throws -> T {
        try cancellation?.checkCancellation()
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try cancellation?.checkCancellation()
            let value = try body()
            try beforeMutationCommitObserver?(mutationKind)
            try cancellation?.checkCancellation()
            try execUnlocked("COMMIT;")
            didMutationCommitObserver?(mutationKind)
            return value
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func withLockedSQLiteOperation<T>(
        cancellation: ToolCallCancellation?,
        maximumBusyWaitSeconds: TimeInterval = 3,
        checkAfterSuccess: Bool = false,
        _ body: () throws -> T
    ) throws -> T {
        let control = SQLiteStoreOperationControl(
            cancellation: cancellation,
            busyRetryObserver: sqliteBusyRetryObserver,
            maximumBusyWaitSeconds: maximumBusyWaitSeconds
        )
        while !lock.lock(before: Date().addingTimeInterval(0.01)) {
            try control.checkBusyBudget()
        }
        defer { lock.unlock() }
        return try withSQLiteControlUnlocked(control: control) {
            let value = try body()
            if checkAfterSuccess {
                try cancellation?.checkCancellation()
            }
            return value
        }
    }

    private func withSQLiteControlUnlocked<T>(
        control: SQLiteStoreOperationControl,
        _ body: () throws -> T
    ) throws -> T {
        guard let db else { throw StoreError.openFailed("nil db") }
        try control.checkCancellation()
        let context = Unmanaged.passUnretained(control).toOpaque()
        sqlite3_busy_handler(db, sqliteStoreBusyHandler, context)
        sqlite3_progress_handler(db, 1_000, sqliteStoreProgressHandler, context)
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            sqlite3_busy_timeout(db, 3_000)
        }
        do {
            return try body()
        } catch {
            try control.checkCancellation()
            throw error
        }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw sqliteStepError(rc)
        }
    }

    private func sqliteStepError(_ result: Int32) -> StoreError {
        guard let db else { return .openFailed("nil db") }
        if result == SQLITE_BUSY || result == SQLITE_LOCKED {
            return .execFailed("database is busy")
        }
        return .execFailed(String(cString: sqlite3_errmsg(db)))
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
