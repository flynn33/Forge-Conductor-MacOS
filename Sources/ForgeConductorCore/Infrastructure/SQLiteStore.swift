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
    static let schemaVersion = 8
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
        CREATE TABLE IF NOT EXISTS continuity_ingress_revisions (
            continuity_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision > 0),
            project_id TEXT NOT NULL,
            project_generation INTEGER NOT NULL CHECK(project_generation > 0),
            task_id TEXT NOT NULL,
            authorization_json BLOB NOT NULL,
            authorization_sha256 TEXT NOT NULL,
            packet_json BLOB NOT NULL,
            packet_sha256 TEXT NOT NULL,
            resume_ready INTEGER NOT NULL CHECK(resume_ready IN (0,1)),
            committed_at TEXT NOT NULL,
            invalidated INTEGER NOT NULL DEFAULT 0 CHECK(invalidated IN (0,1)),
            PRIMARY KEY(continuity_id,revision),
            UNIQUE(continuity_id,packet_sha256)
        );
        CREATE INDEX IF NOT EXISTS idx_continuity_ingress_scope
            ON continuity_ingress_revisions(project_id,project_generation,task_id);
        CREATE TABLE IF NOT EXISTS continuity_ingress_outbox (
            operation_id TEXT PRIMARY KEY,
            continuity_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            packet_sha256 TEXT NOT NULL,
            operation_key_sha256 TEXT NOT NULL UNIQUE,
            explicitly_requested INTEGER NOT NULL DEFAULT 0 CHECK(explicitly_requested IN (0,1)),
            state TEXT NOT NULL CHECK(state IN ('pending','claimed','acknowledged','blocked','invalidated')),
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 8),
            next_attempt_at TEXT NOT NULL,
            lease_owner TEXT,
            lease_token TEXT,
            lease_expires_at TEXT,
            last_error_code TEXT,
            acceptance_receipt_sha256 TEXT,
            acknowledged_at TEXT,
            FOREIGN KEY(continuity_id,revision)
                REFERENCES continuity_ingress_revisions(continuity_id,revision),
            UNIQUE(continuity_id,revision)
        );
        CREATE INDEX IF NOT EXISTS idx_continuity_ingress_delivery
            ON continuity_ingress_outbox(state,next_attempt_at);
        CREATE TABLE IF NOT EXISTS continuity_ingress_invalidations (
            project_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            through_generation INTEGER NOT NULL CHECK(through_generation > 0),
            invalidated_at TEXT NOT NULL,
            PRIMARY KEY(project_id,task_id)
        );
        """)
        if try !tableHasColumnUnlocked(table: "continuity_ingress_outbox", column: "explicitly_requested") {
            try execUnlocked("""
                ALTER TABLE continuity_ingress_outbox ADD COLUMN explicitly_requested
                    INTEGER NOT NULL DEFAULT 0 CHECK(explicitly_requested IN (0,1));
                """)
        }
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
                try handoffUpsertUnlocked(
                    packet, json: json, timestamp: noteTimestamp, cancellation: cancellation
                )
            }
        }
    }

    private func handoffUpsertUnlocked(
        _ packet: HandoffPacket,
        json: String,
        timestamp: String,
        cancellation: ToolCallCancellation?
    ) throws {
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
        ) { statement in
            bind(statement, 1, packet.id)
            bind(statement, 2, packet.createdAt)
            bind(statement, 3, packet.updatedAt)
            bind(statement, 4, packet.source.rawValue)
            sqlite3_bind_int(statement, 5, packet.resumeReady ? 1 : 0)
            bind(statement, 6, json)
            bind(statement, 7, packet.clientID)
            try stepDone(statement)
        }
        if try handoffRequiresAuthorizationUnlocked(packet.id) {
            // A task-owned packet remains in the compatibility table for trusted
            // migration/manager reads, but cannot become a global memory pointer.
            // Reconcile also removes a pointer published before this ID acquired
            // immutable ownership, without reading the owned packet's content.
            try repairLegacyContinuityPointersUnlocked(timestamp: timestamp)
            return
        }
        try memorySetUnlocked(
            key: "continuity/latest", body: packet.id,
            tags: ["continuity", "latest"], timestamp: timestamp
        )
        if packet.resumeReady {
            try cancellation?.checkCancellation()
            try memorySetUnlocked(
                key: "continuity/resume_ready", body: packet.id,
                tags: ["continuity", "resume"], timestamp: timestamp
            )
        }
    }

    // MARK: - Immutable authorized handoff ingress

    /// Commits the authoritative legacy-compatible packet, its immutable authorized
    /// revision and (when eligible) the delivery intent in one source transaction.
    /// It does not contact a manager/provider or infer authority from packet content.
    public func handoffCommit(
        _ packet: HandoffPacket,
        authorization: ContinuityIngressAuthorization,
        automaticHandoffEnabled: Bool,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffCommit {
        try cancellation?.checkCancellation()
        try authorization.validate()
        try Self.validateIngressPacketBounds(packet)
        guard ContinuityIngressLimits.validHandoffID(packet.id),
              let decodedPacket = HandoffPacket.fromDictionary(packet.asDictionary()) else {
            throw ContinuityIngressError.invalidRequest("handoff_packet")
        }
        let packetBytes = try ForgeJSONCanonicalizationV1.data(from: packet.asDictionary())
        guard packetBytes.count <= ContinuityIngressLimits.maximumPacketBytes else {
            throw ContinuityIngressError.capacityExceeded("packet bytes")
        }
        guard try ForgeJSONCanonicalizationV1.data(from: decodedPacket.asDictionary()) == packetBytes else {
            throw ContinuityIngressError.invalidRequest("handoff_packet_roundtrip")
        }
        let packetSHA256 = JSONSupport.sha256Hex(packetBytes)
        let authorityBytes = try authorization.encodedJSON()
        let timestamp = try ingressTimestamp()
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                try requireIngressAuthorityUnlocked(authorization, continuityID: packet.id)
                let revision: ContinuityHandoffRevision
                if let existing = try ingressRevisionForDigestUnlocked(
                    continuityID: packet.id, packetSHA256: packetSHA256
                ) {
                    // A repeated old commit must not rewind the mutable compatibility
                    // projection after another writer has committed a newer packet.
                    guard existing.authorization == authorization,
                          existing.canonicalPacketJSON == packetBytes else {
                        throw ContinuityIngressError.authorityMismatch
                    }
                    revision = existing
                } else {
                    guard (try queryIntUnlocked("SELECT COUNT(*) FROM continuity_ingress_revisions")
                        ?? 0) < ContinuityIngressLimits.maximumRevisions else {
                        throw ContinuityIngressError.capacityExceeded("retained revisions")
                    }
                    let nextRevision = try withStatementUnlocked(
                        "SELECT COALESCE(MAX(revision),0) FROM continuity_ingress_revisions WHERE continuity_id=?"
                    ) { statement -> Int64 in
                        bind(statement, 1, packet.id)
                        guard sqlite3_step(statement) == SQLITE_ROW else {
                            throw ContinuityIngressError.integrityFailure("revision allocation failed")
                        }
                        let previous = sqlite3_column_int64(statement, 0)
                        let next = previous.addingReportingOverflow(1)
                        guard !next.overflow, next.partialValue > 0 else {
                            throw ContinuityIngressError.capacityExceeded("revision sequence")
                        }
                        return next.partialValue
                    }
                    let identity = try ContinuityHandoffIdentity(
                        continuityID: packet.id, revision: nextRevision, packetSHA256: packetSHA256
                    )
                    try withStatementUnlocked(
                        """
                        INSERT INTO continuity_ingress_revisions(
                            continuity_id,revision,project_id,project_generation,task_id,
                            authorization_json,authorization_sha256,packet_json,packet_sha256,
                            resume_ready,committed_at
                        ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """
                    ) { statement in
                        bind(statement, 1, packet.id)
                        sqlite3_bind_int64(statement, 2, nextRevision)
                        bind(statement, 3, authorization.projectID.description)
                        sqlite3_bind_int64(statement, 4, Int64(authorization.projectGeneration.rawValue))
                        bind(statement, 5, authorization.taskID.uuidString.lowercased())
                        bindIngressBytes(statement, 6, authorityBytes)
                        bind(statement, 7, JSONSupport.sha256Hex(authorityBytes))
                        bindIngressBytes(statement, 8, packetBytes)
                        bind(statement, 9, packetSHA256)
                        sqlite3_bind_int(statement, 10, packet.resumeReady ? 1 : 0)
                        bind(statement, 11, timestamp)
                        try stepDone(statement)
                    }
                    try handoffUpsertUnlocked(
                        packet,
                        json: String(decoding: packetBytes, as: UTF8.self),
                        timestamp: timestamp,
                        cancellation: cancellation
                    )
                    revision = ContinuityHandoffRevision(
                        identity: identity, authorization: authorization,
                        canonicalPacketJSON: packetBytes,
                        resumeReady: packet.resumeReady, committedAt: timestamp
                    )
                }
                let delivery: ContinuityHandoffDelivery?
                if automaticHandoffEnabled && revision.resumeReady {
                    delivery = try enqueueIngressUnlocked(
                        revision, explicitlyRequested: false, timestamp: timestamp
                    )
                } else {
                    // Disabling automatic delivery never modifies an existing explicit
                    // submission or turns a soft checkpoint into a provider action.
                    delivery = try ingressDeliveryForRevisionUnlocked(revision.identity)
                }
                return ContinuityHandoffCommit(revision: revision, delivery: delivery)
            }
        }
    }

    /// Explicit and automatic submissions use this same immutable operation key.
    /// The caller has already checked current policy and assignment authority.
    public func enqueueContinuityHandoff(
        identity: ContinuityHandoffIdentity,
        authorization: ContinuityIngressAuthorization,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffDelivery {
        try authorization.validate()
        let timestamp = try ingressTimestamp()
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                try requireIngressAuthorityUnlocked(authorization, continuityID: identity.continuityID)
                let revision = try requiredIngressRevisionUnlocked(identity)
                guard revision.authorization == authorization else {
                    throw ContinuityIngressError.authorityMismatch
                }
                guard revision.resumeReady else {
                    throw ContinuityIngressError.invalidRequest("handoff_is_not_resume_ready")
                }
                return try enqueueIngressUnlocked(
                    revision, explicitlyRequested: true, timestamp: timestamp
                )
            }
        }
    }

    public func continuityHandoffRevision(
        identity: ContinuityHandoffIdentity,
        authorization: ContinuityIngressAuthorization,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffRevision {
        try authorization.validate()
        return try withLockedSQLiteOperation(cancellation: cancellation, checkAfterSuccess: true) {
            try requireIngressAuthorityUnlocked(authorization, continuityID: identity.continuityID)
            let revision = try requiredIngressRevisionUnlocked(identity)
            guard revision.authorization == authorization else {
                throw ContinuityIngressError.authorityMismatch
            }
            return revision
        }
    }

    /// Resolves only this exact source ID after checking its immutable task scope.
    /// It never consults the global mutable handoff or compatibility pointer notes.
    public func continuityLatestRevision(
        continuityID: String,
        authorization: ContinuityIngressAuthorization,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffRevision? {
        guard ContinuityIngressLimits.validHandoffID(continuityID) else {
            throw ContinuityIngressError.invalidRequest("continuity_id")
        }
        try authorization.validate()
        return try withLockedSQLiteOperation(cancellation: cancellation, checkAfterSuccess: true) {
            try requireIngressAuthorityUnlocked(authorization, continuityID: continuityID)
            return try withStatementUnlocked(
                Self.ingressRevisionSelect + " WHERE continuity_id=? ORDER BY revision DESC LIMIT 1"
            ) { statement in
                bind(statement, 1, continuityID)
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                return try decodeIngressRevision(statement)
            }
        }
    }

    /// Metadata-only compatibility guard; it never reads or returns packet data.
    public func continuityHandoffRequiresAuthorization(
        continuityID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        guard ContinuityIngressLimits.validHandoffID(continuityID) else {
            throw ContinuityIngressError.invalidRequest("continuity_id")
        }
        return try withLockedSQLiteOperation(cancellation: cancellation, checkAfterSuccess: true) {
            try handoffRequiresAuthorizationUnlocked(continuityID)
        }
    }

    /// Bounded internal-manager queue inventory. Public status must authorize the
    /// caller before reading/returning an operation from this persistence boundary.
    public func pendingContinuityHandoffs(
        limit: Int = ContinuityIngressLimits.maximumQueryRows,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [ContinuityHandoffDelivery] {
        guard (1...ContinuityIngressLimits.maximumQueryRows).contains(limit) else {
            throw ContinuityIngressError.invalidRequest("query_limit")
        }
        let timestamp = try ingressTimestamp()
        return try withLockedSQLiteOperation(cancellation: cancellation, checkAfterSuccess: true) {
            let identifiers = try withStatementUnlocked(
                """
                SELECT operation_id FROM continuity_ingress_outbox
                WHERE (state='pending' AND next_attempt_at<=?)
                   OR (state='claimed' AND lease_expires_at<=?)
                ORDER BY next_attempt_at,operation_id LIMIT ?
                """
            ) { statement -> [UUID] in
                bind(statement, 1, timestamp)
                bind(statement, 2, timestamp)
                sqlite3_bind_int(statement, 3, Int32(limit))
                var values: [UUID] = []
                while true {
                    try cancellation?.checkCancellation()
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                    guard values.count < limit,
                          let id = try ingressText(statement, 0, maximumBytes: 36)
                            .flatMap(UUID.init(uuidString:)) else {
                        throw ContinuityIngressError.integrityFailure("invalid delivery identifier")
                    }
                    values.append(id)
                }
                return values
            }
            return try identifiers.map { try requiredIngressDeliveryUnlocked($0) }
        }
    }

    public func continuityDelivery(
        operationID: UUID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffDelivery? {
        try withLockedSQLiteOperation(cancellation: cancellation, checkAfterSuccess: true) {
            try ingressDeliveryUnlocked(operationID)
        }
    }

    /// Manager-only metadata pagination. A corrupt payload cannot prevent IDs for
    /// independent due operations from being returned. Callers retain one cursor,
    /// decode each delivery separately and wrap after an empty page.
    func pendingContinuityHandoffIDs(
        limit: Int,
        afterOperationID: UUID? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [UUID] {
        guard (1...ContinuityIngressLimits.maximumQueryRows).contains(limit) else {
            throw ContinuityIngressError.invalidRequest("query_limit")
        }
        let timestamp = try ingressTimestamp()
        let cursorPredicate = afterOperationID == nil ? "" : " AND operation_id>?"
        return try withControlledStatement(
            """
            SELECT operation_id FROM continuity_ingress_outbox
            WHERE ((state='pending' AND next_attempt_at<=?)
                OR (state='claimed' AND lease_expires_at<=?))
            """ + cursorPredicate + " ORDER BY operation_id LIMIT ?",
            cancellation: cancellation
        ) { statement in
            bind(statement, 1, timestamp)
            bind(statement, 2, timestamp)
            if let afterOperationID {
                bind(statement, 3, afterOperationID.uuidString.lowercased())
                sqlite3_bind_int(statement, 4, Int32(limit))
            } else {
                sqlite3_bind_int(statement, 3, Int32(limit))
            }
            var identifiers: [UUID] = []
            while true {
                try cancellation?.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                guard identifiers.count < limit,
                      let value = try ingressText(statement, 0, maximumBytes: 36),
                      let id = UUID(uuidString: value), value == id.uuidString.lowercased() else {
                    throw ContinuityIngressError.integrityFailure("invalid delivery identifier")
                }
                identifiers.append(id)
            }
            return identifiers
        }
    }

    /// Isolates one malformed eligible source row without granting a caller the
    /// ability to quarantine valid work or an operation owned by a live lease.
    @discardableResult
    func quarantineMalformedContinuityDelivery(
        operationID: UUID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        let timestamp = try ingressTimestamp()
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                let eligible = try withStatementUnlocked(
                    """
                    SELECT 1 FROM continuity_ingress_outbox WHERE operation_id=? AND (
                        (state='pending' AND next_attempt_at<=?)
                        OR (state='claimed' AND lease_expires_at<=?))
                    """
                ) { statement -> Bool in
                    bind(statement, 1, operationID.uuidString.lowercased())
                    bind(statement, 2, timestamp)
                    bind(statement, 3, timestamp)
                    let result = sqlite3_step(statement)
                    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw sqliteStepError(result) }
                    return result == SQLITE_ROW
                }
                guard eligible else { return false }
                do {
                    _ = try requiredIngressDeliveryUnlocked(operationID)
                    return false
                } catch ContinuityIngressError.integrityFailure(_) {
                    // Keep the corrupted source snapshot intact for diagnostics;
                    // block only its queue row and revoke an already expired claim.
                    try withStatementUnlocked(
                        """
                        UPDATE continuity_ingress_outbox SET state='blocked',
                            last_error_code='source_integrity_failure',
                            lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL
                        WHERE operation_id=?
                        """
                    ) { statement in
                        bind(statement, 1, operationID.uuidString.lowercased())
                        try stepDone(statement)
                    }
                    return changesUnlocked() == 1
                }
            }
        }
    }

    public func claimContinuityHandoff(
        operationID: UUID,
        owner: String,
        leaseSeconds: TimeInterval = 30,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityDeliveryClaim? {
        guard Self.validIngressLabel(owner), leaseSeconds.isFinite,
              (1...ContinuityIngressLimits.maximumLeaseSeconds).contains(leaseSeconds) else {
            throw ContinuityIngressError.invalidRequest("delivery_lease")
        }
        let now = clock.now()
        let timestamp = try ingressTimestamp(now)
        let expiry = try ingressTimestamp(now.addingTimeInterval(leaseSeconds))
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                guard let current = try ingressDeliveryUnlocked(operationID) else { return nil }
                try requireIngressAuthorityUnlocked(
                    current.handoff.authorization, continuityID: current.handoff.identity.continuityID
                )
                guard (current.state == .pending && current.nextAttemptAt <= timestamp)
                    || (current.state == .claimed && (current.leaseExpiresAt ?? "~") <= timestamp) else {
                    return nil
                }
                if current.attempts >= ContinuityIngressLimits.maximumAttempts {
                    try withStatementUnlocked(
                        """
                        UPDATE continuity_ingress_outbox SET state='blocked',last_error_code='delivery_attempt_limit',
                            lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL WHERE operation_id=?
                        """
                    ) { statement in
                        bind(statement, 1, operationID.uuidString.lowercased())
                        try stepDone(statement)
                    }
                    return nil
                }
                let token = UUID()
                try withStatementUnlocked(
                    """
                    UPDATE continuity_ingress_outbox SET state='claimed',attempts=attempts+1,
                        lease_owner=?,lease_token=?,lease_expires_at=? WHERE operation_id=?
                    """
                ) { statement in
                    bind(statement, 1, owner)
                    bind(statement, 2, token.uuidString.lowercased())
                    bind(statement, 3, expiry)
                    bind(statement, 4, operationID.uuidString.lowercased())
                    try stepDone(statement)
                }
                return ContinuityDeliveryClaim(
                    delivery: try requiredIngressDeliveryUnlocked(operationID), owner: owner, token: token
                )
            }
        }
    }

    /// Revalidates source ownership and the live claim using the source clock.
    /// The manager calls this before attempting control-plane acceptance.
    func validateContinuityHandoffClaim(
        claim: ContinuityDeliveryClaim,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffDelivery {
        try withLockedSQLiteOperation(cancellation: cancellation, checkAfterSuccess: true) {
            try requireIngressClaimUnlocked(claim, timestamp: ingressTimestamp())
        }
    }

    /// Records an exact control-plane acceptance receipt after its durable commit.
    /// A repeated acknowledgment with the same claim and receipt is idempotent.
    public func acknowledgeContinuityHandoff(
        claim: ContinuityDeliveryClaim,
        acceptanceReceiptSHA256: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffDelivery {
        guard ContinuityIngressLimits.validSHA256(acceptanceReceiptSHA256) else {
            throw ContinuityIngressError.invalidRequest("acceptance_receipt_sha256")
        }
        let timestamp = try ingressTimestamp()
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                let current = try requireIngressClaimUnlocked(claim, timestamp: timestamp, allowAcknowledged: true)
                if current.state == .acknowledged {
                    guard current.acceptanceReceiptSHA256 == acceptanceReceiptSHA256 else {
                        throw ContinuityIngressError.deliveryConflict
                    }
                    return current
                }
                try withStatementUnlocked(
                    """
                    UPDATE continuity_ingress_outbox SET state='acknowledged',
                        acceptance_receipt_sha256=?,acknowledged_at=?,last_error_code=NULL
                    WHERE operation_id=?
                    """
                ) { statement in
                    bind(statement, 1, acceptanceReceiptSHA256)
                    bind(statement, 2, timestamp)
                    bind(statement, 3, current.operationID.uuidString.lowercased())
                    try stepDone(statement)
                }
                return try requiredIngressDeliveryUnlocked(current.operationID)
            }
        }
    }

    public func retryContinuityHandoff(
        claim: ContinuityDeliveryClaim,
        errorCode: String,
        retryDelaySeconds: TimeInterval,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityHandoffDelivery {
        guard Self.validIngressLabel(errorCode), retryDelaySeconds.isFinite,
              (1...ContinuityIngressLimits.maximumRetryDelaySeconds).contains(retryDelaySeconds) else {
            throw ContinuityIngressError.invalidRequest("retry_policy")
        }
        let now = clock.now()
        let timestamp = try ingressTimestamp(now)
        let retryAt = try ingressTimestamp(now.addingTimeInterval(retryDelaySeconds))
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                let current = try requireIngressClaimUnlocked(claim, timestamp: timestamp)
                let state: ContinuityDeliveryState = current.attempts >= ContinuityIngressLimits.maximumAttempts
                    ? .blocked : .pending
                try withStatementUnlocked(
                    """
                    UPDATE continuity_ingress_outbox SET state=?,next_attempt_at=?,last_error_code=?,
                        lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL WHERE operation_id=?
                    """
                ) { statement in
                    bind(statement, 1, state.rawValue)
                    bind(statement, 2, retryAt)
                    bind(statement, 3, errorCode)
                    bind(statement, 4, current.operationID.uuidString.lowercased())
                    try stepDone(statement)
                }
                return try requiredIngressDeliveryUnlocked(current.operationID)
            }
        }
    }

    /// Exact read for an already authenticated operation-status callback. Source
    /// metadata is matched before its packet or outbox receipt is materialized.
    func continuityOperationProgressSource(acceptance: ContinuityIngressAcceptanceReceipt,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityOperationProgressEvidence {
        try withLockedSQLiteOperation(cancellation: cancellation, checkAfterSuccess: true) {
            try validateContinuityOperationSourceMetadataUnlocked(acceptance)
            let source = try requiredIngressRevisionUnlocked(acceptance.sourceIdentity, allowInvalidated: true)
            let delivery = try ingressDeliveryUnlocked(acceptance.operationID)
            guard source == acceptance.source,
                  delivery == nil || delivery?.handoff == source else { throw ContinuityIngressError.authorityMismatch }
            return ContinuityOperationProgressEvidence(source: source, delivery: delivery, canonical: nil)
        }
    }

    private func validateContinuityOperationSourceMetadataUnlocked(_ acceptance: ContinuityIngressAcceptanceReceipt) throws {
        let authority = acceptance.authorization
        let authoritySHA = JSONSupport.sha256Hex(try authority.encodedJSON())
        try withStatementUnlocked("""
            SELECT project_id,project_generation,task_id,authorization_sha256,packet_sha256
            FROM continuity_ingress_revisions WHERE continuity_id=? AND revision=? LIMIT 1
            """) { statement in
            bind(statement, 1, acceptance.sourceIdentity.continuityID)
            sqlite3_bind_int64(statement, 2, acceptance.sourceIdentity.revision)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw sqliteStepError(result) }
            guard result == SQLITE_ROW,
                  try ingressText(statement, 0, maximumBytes: 36) == authority.projectID.description,
                  sqlite3_column_int64(statement, 1) == Int64(authority.projectGeneration.rawValue),
                  try ingressText(statement, 2, maximumBytes: 36) == authority.taskID.uuidString.lowercased(),
                  try ingressText(statement, 3, maximumBytes: 64) == authoritySHA,
                  try ingressText(statement, 4, maximumBytes: 64) == acceptance.sourceIdentity.packetSHA256 else {
                throw ContinuityIngressError.authorityMismatch
            }
        }
    }

    /// Invoked only inside the control plane's exact cancellation claim guard.
    /// Retains acknowledged acceptance evidence and invalidates only this frozen
    /// revision; neither the task nor another revision is revoked here.
    func cancelContinuitySourceDelivery(request: ContinuityOperationCancellationRequest,
        acceptance: ContinuityIngressAcceptanceReceipt, cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationCancellationMarker {
        guard request.operationID == acceptance.operationID, request.runID == acceptance.runID,
              request.authorization == acceptance.authorization, request.sourceIdentity == acceptance.sourceIdentity,
              request.acceptanceReceiptSHA256 == acceptance.receiptSHA256,
              try ContinuityOperationCancellationRequest.storedSnapshot(from: request.canonicalRequestJSON,
                acceptance: acceptance) == request else {
            throw ContinuityIngressError.authorityMismatch
        }
        let authoritySHA = JSONSupport.sha256Hex(try request.authorization.encodedJSON())
        let cancellationCode = "operation_cancelled:\(request.requestSHA256)"
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                try validateContinuityOperationSourceMetadataUnlocked(acceptance)
                let prior = try requiredIngressDeliveryUnlocked(request.operationID)
                guard prior.handoff.authorization == acceptance.authorization,
                      prior.handoff.identity == acceptance.sourceIdentity,
                      prior.handoff.canonicalPacketJSON == acceptance.source.canonicalPacketJSON,
                      prior.acceptanceReceiptSHA256 == nil || prior.acceptanceReceiptSHA256 == acceptance.receiptSHA256 else {
                    throw ContinuityIngressError.authorityMismatch
                }
                if prior.lastErrorCode != cancellationCode {
                    guard prior.lastErrorCode?.hasPrefix("operation_cancelled:") != true else {
                        throw ContinuityIngressError.deliveryConflict
                    }
                    let timestamp = try ingressTimestamp()
                    try withStatementUnlocked("""
                        UPDATE continuity_ingress_revisions SET invalidated=1
                        WHERE continuity_id=? AND revision=? AND packet_sha256=? AND authorization_sha256=?
                        """) { statement in
                        bind(statement, 1, request.sourceIdentity.continuityID)
                        sqlite3_bind_int64(statement, 2, request.sourceIdentity.revision)
                        bind(statement, 3, request.sourceIdentity.packetSHA256); bind(statement, 4, authoritySHA)
                        try stepDone(statement)
                    }
                    guard changesUnlocked() == 1 else { throw ContinuityIngressError.deliveryConflict }
                    // An acknowledged row retains its original claim and receipt.
                    // Other rows lose only their now-invalid delivery claim.
                    try withStatementUnlocked("""
                        UPDATE continuity_ingress_outbox SET last_error_code=?,next_attempt_at=?,
                            state=CASE WHEN state='acknowledged' THEN state ELSE 'invalidated' END,
                            lease_owner=CASE WHEN state='acknowledged' THEN lease_owner ELSE NULL END,
                            lease_token=CASE WHEN state='acknowledged' THEN lease_token ELSE NULL END,
                            lease_expires_at=CASE WHEN state='acknowledged' THEN lease_expires_at ELSE NULL END
                        WHERE operation_id=? AND continuity_id=? AND revision=? AND packet_sha256=?
                        """) { statement in
                        bind(statement, 1, cancellationCode); bind(statement, 2, timestamp)
                        bind(statement, 3, request.operationID.uuidString.lowercased())
                        bind(statement, 4, request.sourceIdentity.continuityID)
                        sqlite3_bind_int64(statement, 5, request.sourceIdentity.revision)
                        bind(statement, 6, request.sourceIdentity.packetSHA256)
                        try stepDone(statement)
                    }
                    guard changesUnlocked() == 1 else { throw ContinuityIngressError.deliveryConflict }
                }
                let retained = try requiredIngressDeliveryUnlocked(request.operationID)
                let invalidated = try withStatementUnlocked("""
                    SELECT invalidated FROM continuity_ingress_revisions WHERE continuity_id=? AND revision=?
                    """) { statement -> Bool in
                    bind(statement, 1, request.sourceIdentity.continuityID)
                    sqlite3_bind_int64(statement, 2, request.sourceIdentity.revision)
                    return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 1
                }
                guard invalidated, retained.lastErrorCode == cancellationCode,
                      retained.state == .invalidated || retained.state == .acknowledged else {
                    throw ContinuityIngressError.integrityFailure("source cancellation marker differs")
                }
                let evidence = try ForgeJSONCanonicalizationV1.data(from: [
                    "schema_version": 1, "request_sha256": request.requestSHA256,
                    "operation_id": retained.operationID.uuidString.lowercased(),
                    "continuity_id": retained.handoff.identity.continuityID,
                    "revision": retained.handoff.identity.revision,
                    "packet_sha256": retained.handoff.identity.packetSHA256,
                    "authorization_sha256": authoritySHA, "invalidated": invalidated,
                    "delivery_state": retained.state.rawValue, "attempts": retained.attempts,
                    "last_error_code": retained.lastErrorCode as Any? ?? NSNull(),
                    "recorded_at": retained.nextAttemptAt,
                    "acceptance_receipt_sha256": retained.acceptanceReceiptSHA256 as Any? ?? NSNull(),
                    "acknowledged_at": retained.acknowledgedAt as Any? ?? NSNull(),
                    "lease_owner": retained.leaseOwner as Any? ?? NSNull(),
                    "lease_token": retained.leaseToken?.uuidString.lowercased() as Any? ?? NSNull(),
                    "lease_expires_at": retained.leaseExpiresAt as Any? ?? NSNull(),
                    "explicitly_requested": retained.explicitlyRequested,
                ])
                return try ContinuityOperationCancellationMarker(request: request, store: .sourceOutbox,
                    evidenceSHA256: JSONSupport.sha256Hex(evidence), recordedAt: retained.nextAttemptAt)
            }
        }
    }

    /// Manager-only cancellation of this claim before any control-plane submission.
    /// The caller must have re-read native policy and must not call this after an
    /// acceptance attempt. This primitive proves neither policy nor task permission.
    /// A concurrent explicit start wins without losing its claim or attempt.
    @discardableResult
    func deferUnsubmittedContinuityHandoff(
        claim: ContinuityDeliveryClaim,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        let timestamp = try ingressTimestamp()
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                let current = try requireIngressClaimUnlocked(claim, timestamp: timestamp)
                guard current.nextAttemptAt <= timestamp, current.attempts > 0 else {
                    throw ContinuityIngressError.deliveryConflict
                }
                guard !current.explicitlyRequested else { return false }
                let restoredAttempts = current.attempts.subtractingReportingOverflow(1)
                guard !restoredAttempts.overflow, restoredAttempts.partialValue >= 0 else {
                    throw ContinuityIngressError.integrityFailure("unsubmitted delivery attempt is invalid")
                }
                try withStatementUnlocked(
                    """
                    UPDATE continuity_ingress_outbox SET state='pending',attempts=?,
                        lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
                        last_error_code='automatic_delivery_disabled'
                    WHERE operation_id=? AND state='claimed' AND lease_owner=? AND lease_token=?
                        AND explicitly_requested=0 AND acceptance_receipt_sha256 IS NULL
                    """
                ) { statement in
                    sqlite3_bind_int64(statement, 1, Int64(restoredAttempts.partialValue))
                    bind(statement, 2, current.operationID.uuidString.lowercased())
                    bind(statement, 3, claim.owner)
                    bind(statement, 4, claim.token.uuidString.lowercased())
                    try stepDone(statement)
                    guard changesUnlocked() == 1 else { throw ContinuityIngressError.deliveryConflict }
                }
                return true
            }
        }
    }

    /// Maintains a durable generation high-water mark. Nil task invalidates the
    /// entire project through this generation; an exact task leaves peers intact.
    @discardableResult
    public func invalidateContinuityIngress(
        projectID: ProjectID,
        throughGeneration: ProjectGeneration,
        taskID: UUID? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Int {
        guard throughGeneration.rawValue > 0,
              throughGeneration.rawValue <= UInt64(Int64.max) else {
            throw ContinuityIngressError.invalidRequest("project_generation")
        }
        let task = taskID?.uuidString.lowercased() ?? ""
        let timestamp = try ingressTimestamp()
        return try withLockedSQLiteOperation(cancellation: cancellation) {
            try ingressTransactionUnlocked(cancellation: cancellation) {
                let existing = try withStatementUnlocked(
                    "SELECT through_generation FROM continuity_ingress_invalidations WHERE project_id=? AND task_id=?"
                ) { statement -> Bool in
                    bind(statement, 1, projectID.description)
                    bind(statement, 2, task)
                    let result = sqlite3_step(statement)
                    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw sqliteStepError(result) }
                    return result == SQLITE_ROW
                }
                if !existing {
                    guard (try queryIntUnlocked("SELECT COUNT(*) FROM continuity_ingress_invalidations")
                        ?? 0) < ContinuityIngressLimits.maximumInvalidations else {
                        throw ContinuityIngressError.capacityExceeded("invalidation tombstones")
                    }
                }
                try withStatementUnlocked(
                    """
                    INSERT INTO continuity_ingress_invalidations(project_id,task_id,through_generation,invalidated_at)
                    VALUES(?,?,?,?) ON CONFLICT(project_id,task_id) DO UPDATE SET
                        through_generation=MAX(through_generation,excluded.through_generation),
                        invalidated_at=excluded.invalidated_at
                    """
                ) { statement in
                    bind(statement, 1, projectID.description)
                    bind(statement, 2, task)
                    sqlite3_bind_int64(statement, 3, Int64(throughGeneration.rawValue))
                    bind(statement, 4, timestamp)
                    try stepDone(statement)
                }
                try withStatementUnlocked(
                    """
                    UPDATE continuity_ingress_revisions SET invalidated=1
                    WHERE project_id=? AND project_generation<=? AND (?='' OR task_id=?)
                    """
                ) { statement in
                    bind(statement, 1, projectID.description)
                    sqlite3_bind_int64(statement, 2, Int64(throughGeneration.rawValue))
                    bind(statement, 3, task)
                    bind(statement, 4, task)
                    try stepDone(statement)
                }
                try withStatementUnlocked(
                    """
                    UPDATE continuity_ingress_outbox SET state='invalidated',last_error_code='authority_invalidated',
                        lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL
                    WHERE state NOT IN ('acknowledged','invalidated') AND EXISTS (
                        SELECT 1 FROM continuity_ingress_revisions r
                        WHERE r.continuity_id=continuity_ingress_outbox.continuity_id
                            AND r.revision=continuity_ingress_outbox.revision AND r.invalidated=1
                    )
                    """
                ) { statement in try stepDone(statement) }
                return changesUnlocked()
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

    /// Legacy compatibility readers exclude every source ID that has ever gained
    /// immutable task ownership. The SQL predicate runs before packet bytes are
    /// selected; invalidation or a later legacy overwrite cannot remove ownership.
    public func handoffLegacyGet(
        id: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> HandoffPacket? {
        try withControlledStatement(
            "SELECT id,packet_json FROM context_handoffs WHERE id=? AND "
                + Self.legacyHandoffPredicate,
            cancellation: cancellation
        ) { statement in
            bind(statement, 1, id)
            return try handoffPacketFromFirstRow(statement, cancellation: cancellation)
        }
    }

    public func handoffLegacyLatest(
        resumeReadyOnly: Bool = false,
        clientID: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> HandoffPacket? {
        var predicates = [Self.legacyHandoffPredicate]
        if resumeReadyOnly { predicates.append("resume_ready=1") }
        if clientID != nil { predicates.append("client_id=?") }
        let sql = "SELECT id,packet_json FROM context_handoffs WHERE "
            + predicates.joined(separator: " AND ") + " ORDER BY write_sequence DESC LIMIT 1"
        return try withControlledStatement(sql, cancellation: cancellation) { statement in
            if let clientID { bind(statement, 1, clientID) }
            return try handoffPacketFromFirstRow(statement, cancellation: cancellation)
        }
    }

    public func handoffLegacyList(
        limit: Int = 20,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [HandoffPacket] {
        let boundedLimit = max(1, min(limit, 100))
        return try handoffList(
            sql: "SELECT id,packet_json FROM context_handoffs WHERE "
                + Self.legacyHandoffPredicate + " ORDER BY write_sequence DESC LIMIT \(boundedLimit)",
            cancellation: cancellation
        )
    }

    public func handoffLegacyListAll(
        cancellation: ToolCallCancellation? = nil
    ) throws -> [HandoffPacket] {
        try handoffList(
            sql: "SELECT id,packet_json FROM context_handoffs WHERE "
                + Self.legacyHandoffPredicate
                + " ORDER BY write_sequence DESC LIMIT \(Self.maximumHandoffQueryRows)",
            cancellation: cancellation
        )
    }

    private static let legacyHandoffPredicate = """
        NOT EXISTS (
            SELECT 1 FROM continuity_ingress_revisions owned
            WHERE owned.continuity_id=context_handoffs.id
        )
        """

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
                try repairLegacyContinuityPointersUnlocked(timestamp: timestamp)
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
        let predicate = " WHERE " + Self.legacyHandoffPredicate
            + (resumeReadyOnly ? " AND resume_ready=1" : "")
        return try withStatementUnlocked(
            "SELECT id FROM context_handoffs\(predicate) ORDER BY write_sequence DESC LIMIT 1"
        ) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteStepError(result) }
            return textCol(statement, 0)
        }
    }

    private func handoffRequiresAuthorizationUnlocked(_ continuityID: String) throws -> Bool {
        try withStatementUnlocked(
            "SELECT 1 FROM continuity_ingress_revisions WHERE continuity_id=? LIMIT 1"
        ) { statement in
            bind(statement, 1, continuityID)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw sqliteStepError(result) }
            return result == SQLITE_ROW
        }
    }

    private func repairLegacyContinuityPointersUnlocked(timestamp: String) throws {
        let latestID = try handoffIDUnlocked(resumeReadyOnly: false)
        let resumeID = try handoffIDUnlocked(resumeReadyOnly: true)
        try replaceContinuityPointerUnlocked(
            key: "continuity/latest", id: latestID,
            tags: ["continuity", "latest"], timestamp: timestamp
        )
        try replaceContinuityPointerUnlocked(
            key: "continuity/resume_ready", id: resumeID,
            tags: ["continuity", "resume"], timestamp: timestamp
        )
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

    // MARK: - Continuity ingress storage helpers

    private static let ingressRevisionSelect = """
        SELECT continuity_id,revision,project_id,project_generation,task_id,
            authorization_json,authorization_sha256,packet_json,packet_sha256,
            resume_ready,committed_at,invalidated FROM continuity_ingress_revisions
        """

    private func ingressTimestamp(_ date: Date? = nil) throws -> String {
        let value = date ?? clock.now()
        guard value.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(value.timeIntervalSince1970) else {
            throw ContinuityIngressError.invalidRequest("clock")
        }
        return ISO8601.string(from: value)
    }

    private static func validIngressLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func validateIngressPacketBounds(_ packet: HandoffPacket) throws {
        let lists = [packet.blockers, packet.nextActions, packet.keyFiles, packet.decisions]
        guard lists.allSatisfy({ $0.count <= 128 }), packet.agents.count <= 128 else {
            throw ContinuityIngressError.capacityExceeded("packet fields")
        }
        var bytes = 0
        func add(_ value: String?) throws {
            guard let value else { return }
            let sum = bytes.addingReportingOverflow(value.utf8.count)
            guard !sum.overflow, sum.partialValue <= ContinuityIngressLimits.maximumPacketBytes else {
                throw ContinuityIngressError.capacityExceeded("packet bytes")
            }
            bytes = sum.partialValue
        }
        for value in [packet.id, packet.createdAt, packet.updatedAt, packet.chatLabel,
                      packet.clientID, packet.goal, packet.status, packet.projectSlug,
                      packet.cwd, packet.narrative, packet.resumeSeed] {
            try add(value)
        }
        for values in lists { for value in values { try add(value) } }
        for agent in packet.agents {
            for value in [agent.sessionID, agent.agentID, agent.goal, agent.cwd,
                          agent.status, agent.updatedAt, agent.resumeHint] {
                try add(value)
            }
        }
    }

    /// Keep the existing transaction/cancellation observers, while asking SQLite
    /// to flush this source handoff/outbox commit before acknowledging durability.
    private func ingressTransactionUnlocked<Value>(
        cancellation: ToolCallCancellation?,
        _ body: () throws -> Value
    ) throws -> Value {
        let previous = try queryIntUnlocked("PRAGMA synchronous;") ?? 1
        guard (0...3).contains(previous) else {
            throw ContinuityIngressError.integrityFailure("invalid SQLite synchronous mode")
        }
        try execUnlocked("PRAGMA synchronous=FULL;")
        defer { try? execUnlocked("PRAGMA synchronous=\(previous);") }
        return try transactionUnlocked(cancellation: cancellation, mutationKind: .handoff, body)
    }

    private func requireIngressAuthorityUnlocked(
        _ authorization: ContinuityIngressAuthorization,
        continuityID: String
    ) throws {
        let invalidated = try withStatementUnlocked(
            """
            SELECT 1 FROM continuity_ingress_invalidations
            WHERE project_id=? AND (task_id='' OR task_id=?) AND through_generation>=? LIMIT 1
            """
        ) { statement -> Bool in
            bind(statement, 1, authorization.projectID.description)
            bind(statement, 2, authorization.taskID.uuidString.lowercased())
            sqlite3_bind_int64(statement, 3, Int64(authorization.projectGeneration.rawValue))
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw sqliteStepError(result) }
            return result == SQLITE_ROW
        }
        guard !invalidated else { throw ContinuityIngressError.invalidated }
        try withStatementUnlocked(
            "SELECT authorization_json FROM continuity_ingress_revisions WHERE continuity_id=? LIMIT 1"
        ) { statement in
            bind(statement, 1, continuityID)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw sqliteStepError(result) }
            let stored = try ContinuityIngressAuthorization.storedSnapshot(from:
                ingressBytes(statement, 0, maximumBytes: ContinuityIngressLimits.maximumAuthorizationBytes)
            )
            guard stored == authorization else { throw ContinuityIngressError.authorityMismatch }
        }
    }

    private func ingressRevisionForDigestUnlocked(
        continuityID: String,
        packetSHA256: String
    ) throws -> ContinuityHandoffRevision? {
        try withStatementUnlocked(
            Self.ingressRevisionSelect + " WHERE continuity_id=? AND packet_sha256=?"
        ) { statement in
            bind(statement, 1, continuityID)
            bind(statement, 2, packetSHA256)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteStepError(result) }
            return try decodeIngressRevision(statement)
        }
    }

    private func requiredIngressRevisionUnlocked(
        _ identity: ContinuityHandoffIdentity,
        allowInvalidated: Bool = false
    ) throws -> ContinuityHandoffRevision {
        try withStatementUnlocked(
            Self.ingressRevisionSelect + " WHERE continuity_id=? AND revision=?"
        ) { statement in
            bind(statement, 1, identity.continuityID)
            sqlite3_bind_int64(statement, 2, identity.revision)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { throw ContinuityIngressError.notFound }
            guard result == SQLITE_ROW else { throw sqliteStepError(result) }
            let revision = try decodeIngressRevision(statement, allowInvalidated: allowInvalidated)
            guard revision.identity == identity else {
                throw ContinuityIngressError.integrityFailure("exact handoff digest changed")
            }
            return revision
        }
    }

    private func decodeIngressRevision(
        _ statement: OpaquePointer,
        allowInvalidated: Bool = false
    ) throws -> ContinuityHandoffRevision {
        guard let continuityID = try ingressText(statement, 0, maximumBytes: 128),
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
              let project = try ingressText(statement, 2, maximumBytes: 36),
              sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
              let task = try ingressText(statement, 4, maximumBytes: 36),
              let authoritySHA = try ingressText(statement, 6, maximumBytes: 64),
              let packetSHA = try ingressText(statement, 8, maximumBytes: 64),
              sqlite3_column_type(statement, 9) == SQLITE_INTEGER,
              let timestamp = try ingressText(statement, 10, maximumBytes: 32),
              ISO8601.date(from: timestamp) != nil,
              sqlite3_column_type(statement, 11) == SQLITE_INTEGER else {
            throw ContinuityIngressError.integrityFailure("malformed handoff revision")
        }
        let invalidated = sqlite3_column_int(statement, 11)
        guard invalidated == 0 || invalidated == 1 else {
            throw ContinuityIngressError.integrityFailure("invalid revision lifecycle")
        }
        guard allowInvalidated || invalidated == 0 else { throw ContinuityIngressError.invalidated }
        let authorityBytes = try ingressBytes(
            statement, 5, maximumBytes: ContinuityIngressLimits.maximumAuthorizationBytes
        )
        guard JSONSupport.sha256Hex(authorityBytes) == authoritySHA else {
            throw ContinuityIngressError.integrityFailure("stored authorization digest changed")
        }
        let authority = try ContinuityIngressAuthorization.storedSnapshot(from: authorityBytes)
        let packetBytes = try ingressBytes(
            statement, 7, maximumBytes: ContinuityIngressLimits.maximumPacketBytes
        )
        let ready = sqlite3_column_int(statement, 9)
        guard authority.projectID.description == project,
              Int64(authority.projectGeneration.rawValue) == sqlite3_column_int64(statement, 3),
              authority.taskID.uuidString.lowercased() == task,
              ready == 0 || ready == 1,
              JSONSupport.sha256Hex(packetBytes) == packetSHA,
              let object = try JSONSerialization.jsonObject(with: packetBytes) as? [String: Any],
              let packet = HandoffPacket.fromDictionary(object),
              packet.id == continuityID, packet.resumeReady == (ready == 1),
              try ForgeJSONCanonicalizationV1.data(from: packet.asDictionary()) == packetBytes else {
            throw ContinuityIngressError.integrityFailure("immutable handoff content or scope changed")
        }
        return ContinuityHandoffRevision(
            identity: try ContinuityHandoffIdentity(
                continuityID: continuityID, revision: sqlite3_column_int64(statement, 1),
                packetSHA256: packetSHA
            ),
            authorization: authority, canonicalPacketJSON: packetBytes,
            resumeReady: ready == 1, committedAt: timestamp
        )
    }

    private func enqueueIngressUnlocked(
        _ revision: ContinuityHandoffRevision,
        explicitlyRequested: Bool,
        timestamp: String
    ) throws -> ContinuityHandoffDelivery {
        guard revision.resumeReady else {
            throw ContinuityIngressError.invalidRequest("handoff_is_not_resume_ready")
        }
        let key = try ContinuityIngressOperationIdentity(revision: revision)
        if let existing = try ingressDeliveryUnlocked(key.operationID) {
            guard existing.handoff == revision else { throw ContinuityIngressError.authorityMismatch }
            guard existing.state != .invalidated else { throw ContinuityIngressError.invalidated }
            if explicitlyRequested && !existing.explicitlyRequested {
                // Provenance may become explicit after a later authorized start,
                // but this must not revive a terminal row or reset retry/lease state.
                try withStatementUnlocked(
                    "UPDATE continuity_ingress_outbox SET explicitly_requested=1 WHERE operation_id=?"
                ) { statement in
                    bind(statement, 1, key.operationID.uuidString.lowercased())
                    try stepDone(statement)
                }
                return try requiredIngressDeliveryUnlocked(key.operationID)
            }
            return existing
        }
        guard (try queryIntUnlocked(
            "SELECT COUNT(*) FROM continuity_ingress_outbox WHERE state IN ('pending','claimed','blocked')"
        ) ?? 0) < ContinuityIngressLimits.maximumPendingDeliveries else {
            throw ContinuityIngressError.capacityExceeded("pending deliveries")
        }
        try withStatementUnlocked(
            """
            INSERT INTO continuity_ingress_outbox(
                operation_id,continuity_id,revision,packet_sha256,operation_key_sha256,
                explicitly_requested,state,next_attempt_at
            ) VALUES(?,?,?,?,?,?,'pending',?)
            """
        ) { statement in
            bind(statement, 1, key.operationID.uuidString.lowercased())
            bind(statement, 2, revision.identity.continuityID)
            sqlite3_bind_int64(statement, 3, revision.identity.revision)
            bind(statement, 4, revision.identity.packetSHA256)
            bind(statement, 5, key.keySHA256)
            sqlite3_bind_int(statement, 6, explicitlyRequested ? 1 : 0)
            bind(statement, 7, timestamp)
            try stepDone(statement)
        }
        return try requiredIngressDeliveryUnlocked(key.operationID)
    }

    private func ingressDeliveryForRevisionUnlocked(
        _ identity: ContinuityHandoffIdentity
    ) throws -> ContinuityHandoffDelivery? {
        let operationID = try withStatementUnlocked(
            "SELECT operation_id FROM continuity_ingress_outbox WHERE continuity_id=? AND revision=?"
        ) { statement -> UUID? in
            bind(statement, 1, identity.continuityID)
            sqlite3_bind_int64(statement, 2, identity.revision)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW,
                  let id = try ingressText(statement, 0, maximumBytes: 36).flatMap(UUID.init(uuidString:)) else {
                throw ContinuityIngressError.integrityFailure("malformed delivery identifier")
            }
            return id
        }
        return try operationID.map { try requiredIngressDeliveryUnlocked($0) }
    }

    private func requiredIngressDeliveryUnlocked(_ operationID: UUID) throws -> ContinuityHandoffDelivery {
        guard let value = try ingressDeliveryUnlocked(operationID) else { throw ContinuityIngressError.notFound }
        return value
    }

    private func ingressDeliveryUnlocked(_ operationID: UUID) throws -> ContinuityHandoffDelivery? {
        do {
            return try withStatementUnlocked(
                """
                SELECT continuity_id,revision,packet_sha256,operation_key_sha256,state,attempts,
                    next_attempt_at,lease_owner,lease_token,lease_expires_at,last_error_code,
                    acceptance_receipt_sha256,acknowledged_at,explicitly_requested
                FROM continuity_ingress_outbox WHERE operation_id=?
                """
            ) { statement in
                bind(statement, 1, operationID.uuidString.lowercased())
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw sqliteStepError(result) }
                guard let continuityID = try ingressText(statement, 0, maximumBytes: 128),
                      sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                      let packetSHA = try ingressText(statement, 2, maximumBytes: 64),
                      let keySHA = try ingressText(statement, 3, maximumBytes: 64),
                      let state = try ingressText(statement, 4, maximumBytes: 16)
                        .flatMap(ContinuityDeliveryState.init(rawValue:)),
                      sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
                      let nextAt = try ingressText(statement, 6, maximumBytes: 32),
                      ISO8601.date(from: nextAt) != nil,
                      sqlite3_column_type(statement, 13) == SQLITE_INTEGER else {
                    throw ContinuityIngressError.integrityFailure("malformed delivery row")
                }
                let attempts = sqlite3_column_int64(statement, 5)
                let owner = try ingressText(statement, 7, maximumBytes: 128)
                let tokenText = try ingressText(statement, 8, maximumBytes: 36)
                let token = tokenText.flatMap(UUID.init(uuidString:))
                let expiry = try ingressText(statement, 9, maximumBytes: 32)
                let error = try ingressText(statement, 10, maximumBytes: 128)
                let receipt = try ingressText(statement, 11, maximumBytes: 64)
                let acknowledgedAt = try ingressText(statement, 12, maximumBytes: 32)
                let explicit = sqlite3_column_int64(statement, 13)
                guard (0...Int64(ContinuityIngressLimits.maximumAttempts)).contains(attempts),
                      explicit == 0 || explicit == 1,
                      owner.map(Self.validIngressLabel) ?? true,
                      tokenText == nil || token != nil,
                      expiry.map({ ISO8601.date(from: $0) != nil }) ?? true,
                      error.map(Self.validIngressLabel) ?? true,
                      receipt.map(ContinuityIngressLimits.validSHA256) ?? true,
                      acknowledgedAt.map({ ISO8601.date(from: $0) != nil }) ?? true else {
                    throw ContinuityIngressError.integrityFailure("invalid delivery state fields")
                }
                if state == .claimed || state == .acknowledged {
                    guard owner != nil, token != nil, expiry != nil, attempts > 0 else {
                        throw ContinuityIngressError.integrityFailure("delivery lacks claim correlation")
                    }
                } else if owner != nil || token != nil || expiry != nil {
                    throw ContinuityIngressError.integrityFailure("unclaimed delivery has a lease")
                }
                guard (state == .acknowledged) == (receipt != nil && acknowledgedAt != nil),
                      state == .acknowledged || (receipt == nil && acknowledgedAt == nil) else {
                    throw ContinuityIngressError.integrityFailure("delivery acknowledgment is incomplete")
                }
                let revision = try requiredIngressRevisionUnlocked(
                    ContinuityHandoffIdentity(
                        continuityID: continuityID, revision: sqlite3_column_int64(statement, 1),
                        packetSHA256: packetSHA
                    ),
                    allowInvalidated: true
                )
                let expected = try ContinuityIngressOperationIdentity(revision: revision)
                guard expected.operationID == operationID, expected.keySHA256 == keySHA, revision.resumeReady else {
                    throw ContinuityIngressError.integrityFailure("delivery operation identity changed")
                }
                return ContinuityHandoffDelivery(
                    operationID: operationID, handoff: revision, explicitlyRequested: explicit == 1,
                    state: state, attempts: Int(attempts),
                    nextAttemptAt: nextAt, leaseOwner: owner, leaseToken: token,
                    leaseExpiresAt: expiry, lastErrorCode: error,
                    acceptanceReceiptSHA256: receipt, acknowledgedAt: acknowledgedAt
                )
            }
        } catch let error as ContinuityIngressError {
            switch error {
            case .invalidRequest(let field), .capacityExceeded(let field):
                throw ContinuityIngressError.integrityFailure("stored delivery field is invalid: \(field)")
            default:
                throw error
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 3_840 {
            throw ContinuityIngressError.integrityFailure("stored delivery JSON is malformed")
        }
    }

    private func requireIngressClaimUnlocked(
        _ claim: ContinuityDeliveryClaim,
        timestamp: String,
        allowAcknowledged: Bool = false
    ) throws -> ContinuityHandoffDelivery {
        let current = try requiredIngressDeliveryUnlocked(claim.delivery.operationID)
        try requireIngressAuthorityUnlocked(
            claim.delivery.handoff.authorization,
            continuityID: claim.delivery.handoff.identity.continuityID
        )
        guard current.handoff == claim.delivery.handoff,
              current.leaseOwner == claim.owner, current.leaseToken == claim.token,
              (current.state == .claimed && (current.leaseExpiresAt ?? "") > timestamp)
                || (allowAcknowledged && current.state == .acknowledged) else {
            throw ContinuityIngressError.deliveryConflict
        }
        return current
    }

    private func bindIngressBytes(_ statement: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.sqliteTransient)
        }
    }

    private func ingressBytes(
        _ statement: OpaquePointer,
        _ column: Int32,
        maximumBytes: Int
    ) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            throw ContinuityIngressError.integrityFailure("expected a binary canonical snapshot")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= maximumBytes, let pointer = sqlite3_column_blob(statement, column) else {
            throw ContinuityIngressError.integrityFailure("stored snapshot exceeds its byte boundary")
        }
        return Data(bytes: pointer, count: count)
    }

    private func ingressText(
        _ statement: OpaquePointer,
        _ column: Int32,
        maximumBytes: Int
    ) throws -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else {
            throw ContinuityIngressError.integrityFailure("expected a text field")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumBytes, let pointer = sqlite3_column_text(statement, column),
              let value = String(data: Data(bytes: pointer, count: count), encoding: .utf8),
              !value.contains("\0") else {
            throw ContinuityIngressError.integrityFailure("stored text exceeds its byte boundary")
        }
        return value
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
