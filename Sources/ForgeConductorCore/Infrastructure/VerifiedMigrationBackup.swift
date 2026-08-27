// VerifiedMigrationBackup.swift
// Creates bounded, owner-only recovery artifacts before durable-format migrations.

import CryptoKit
import Darwin
import Foundation
import SQLite3

public struct VerifiedMigrationBackupMetadata: Sendable, Equatable {
    fileprivate enum Origin: Sendable {
        case file
        case sqliteSnapshot
    }

    public let url: URL
    public let sha256: String
    public let bytes: UInt64
    fileprivate let origin: Origin

    fileprivate init(
        url: URL,
        sha256: String,
        bytes: UInt64,
        origin: Origin
    ) {
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.origin = origin
    }
}

public enum VerifiedMigrationStorageKind: String, Codable, Sendable {
    case file
    case sqlite
}

public enum VerifiedMigrationManifestState: String, Codable, Sendable {
    case prepared
    case completed
}

public struct VerifiedMigrationBackupManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let migrationID: String
    public let state: VerifiedMigrationManifestState
    public let storageKind: VerifiedMigrationStorageKind
    public let sourceFilename: String
    public let sourceVersion: Int
    public let sourceSHA256: String
    public let sourceBytes: UInt64
    public let backupFilename: String
    public let backupSHA256: String
    public let backupBytes: UInt64
    public let targetVersion: Int
    public let targetSHA256: String?
    public let targetBytes: UInt64?
    public let targetArtifactFilename: String?
    public let rollbackInstructions: [String]
    public let preparedAt: String
    public let completedAt: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case migrationID = "migration_id"
        case state
        case storageKind = "storage_kind"
        case sourceFilename = "source_filename"
        case sourceVersion = "source_version"
        case sourceSHA256 = "source_sha256"
        case sourceBytes = "source_bytes"
        case backupFilename = "backup_filename"
        case backupSHA256 = "backup_sha256"
        case backupBytes = "backup_bytes"
        case targetVersion = "target_version"
        case targetSHA256 = "target_sha256"
        case targetBytes = "target_bytes"
        case targetArtifactFilename = "target_artifact_filename"
        case rollbackInstructions = "rollback_instructions"
        case preparedAt = "prepared_at"
        case completedAt = "completed_at"
    }
}

public enum VerifiedMigrationBackupError: Error, LocalizedError, Sendable {
    case invalidSource(String)
    case corruptSource(String)
    case creationFailed(String)
    case verificationFailed(String)
    case reconciliationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let detail): "Migration backup source is invalid: \(detail)"
        case .corruptSource(let detail): "Migration backup source is corrupt: \(detail)"
        case .creationFailed(let detail): "Migration backup could not be created: \(detail)"
        case .verificationFailed(let detail): "Migration backup verification failed: \(detail)"
        case .reconciliationFailed(let detail): "Migration backup reconciliation failed: \(detail)"
        }
    }
}

struct SQLitePreflightDatabase {
    fileprivate let database: OpaquePointer
    let sourceHasWriteAheadLog: Bool

    func integer(_ sql: String) throws -> Int? {
        try VerifiedMigrationBackup.preflightSQLiteInt(sql, database: database)
    }

    func requireEmptySchemaWhenUnversioned(reportedVersion: Int) throws {
        guard reportedVersion >= 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite schema version cannot be negative"
            )
        }
        guard reportedVersion == 0 else { return }
        let objectCount = try integer("SELECT COUNT(*) FROM main.sqlite_master;") ?? 0
        guard objectCount == 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "unversioned SQLite database is not empty"
            )
        }
        guard !sourceHasWriteAheadLog else {
            throw VerifiedMigrationBackupError.invalidSource(
                "unversioned SQLite database has unresolved write-ahead-log state"
            )
        }
    }

    func migrationSnapshot(
        to backupURL: URL,
        expectedVersion: Int,
        versionQuery: String
    ) throws -> VerifiedMigrationBackupMetadata {
        try VerifiedMigrationBackup.snapshotSQLite(
            database: database,
            to: backupURL,
            expectedVersion: expectedVersion,
            versionQuery: versionQuery
        )
    }
}

struct SQLiteOpenRegistration {
    fileprivate let identity: VerifiedMigrationBackup.SQLiteFileIdentity
}

public enum VerifiedMigrationBackup {
    private static let ownerOnlyPermissions = 0o600
    private static let sqliteBackupDeadline: TimeInterval = 60
    private static let sqliteBackupPageBatch: Int32 = 256
    private static let maximumSQLiteBackupBytes: UInt64 = 4 * 1024 * 1024 * 1024
    private static let processMigrationLock = NSLock()
    private static let openRegistrationLock = NSLock()
    private static var openRegistrationCounts: [SQLiteFileIdentity: Int] = [:]
    private static let preflightAttemptLimit = 3
    private static let manifestSchemaVersion = 1
    private static let maximumManifestBytes = 64 * 1024
    private static let maximumSQLiteBackupLineagesPerSourceVersion = 4

    fileprivate struct SQLiteFileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct SQLiteSourceFileDigest: Equatable {
        let identity: SQLiteFileIdentity
        let bytes: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let sha256: String
    }

    private struct SQLiteSourceState {
        let database: SQLiteSourceFileDigest?
        let writeAheadLog: SQLiteSourceFileDigest?
        let sharedMemory: SQLiteSourceFileDigest?

        func hasSameDurableContent(as other: SQLiteSourceState) -> Bool {
            database == other.database && writeAheadLog == other.writeAheadLog
        }
    }

    /// Serializes migration setup within this process and against other Forge processes.
    public static func withMigrationLock<T>(
        databaseURL: URL,
        timeoutSeconds: TimeInterval,
        _ body: () throws -> T
    ) throws -> T {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "migration lock timeout must be finite and positive"
            )
        }
        let deadlineUptime = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        guard processMigrationLock.lock(before: Date().addingTimeInterval(timeoutSeconds)) else {
            throw VerifiedMigrationBackupError.creationFailed(
                "timed out waiting for the process migration lock"
            )
        }
        defer { processMigrationLock.unlock() }

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lockURL = databaseURL.appendingPathExtension("migration.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "migration lock could not be opened: \(String(cString: strerror(errno)))"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try validateAndHardenOwnerOnlyDescriptor(
            descriptor,
            purpose: "migration lock"
        )

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "migration lock could not be acquired: \(String(cString: strerror(code)))"
                )
            }
            let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "timed out waiting for the interprocess migration lock"
                )
            }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Inspects a stable private copy so rejection never opens or recovers the source database.
    /// The aggregate source family is capped at 4 GiB and retried at most three times under one
    /// deadline. SHM is hashed for evidence but excluded from consistency because normal readers
    /// may update WAL read marks without changing durable main/WAL content.
    static func withNonMutatingSQLitePreflight(
        databaseURL: URL,
        timeoutSeconds: TimeInterval = sqliteBackupDeadline,
        maximumBytes: UInt64 = maximumSQLiteBackupBytes,
        _ inspect: (SQLitePreflightDatabase?) throws -> Void
    ) throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, maximumBytes > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite preflight byte limit and deadline must be positive"
            )
        }
        if try hasRegisteredOpenDatabase(at: databaseURL) {
            return
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        var lastInstability: Error?
        for _ in 0..<preflightAttemptLimit {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            do {
                let before = try sqliteSourceState(
                    databaseURL: databaseURL,
                    maximumBytes: maximumBytes,
                    deadline: deadline
                )
                guard before.database != nil else {
                    try inspect(nil)
                    let after = try sqliteSourceState(
                        databaseURL: databaseURL,
                        maximumBytes: maximumBytes,
                        deadline: deadline
                    )
                    guard before.hasSameDurableContent(as: after) else {
                        throw VerifiedMigrationBackupError.creationFailed(
                            "SQLite source appeared during preflight"
                        )
                    }
                    return
                }

                let stagingRoot = try resetTemporaryDirectory(
                    kind: "sqlite-preflight",
                    key: databaseURL.standardizedFileURL.path
                )
                defer { try? FileManager.default.removeItem(at: stagingRoot) }
                let stagedDatabaseURL = stagingRoot.appendingPathComponent("candidate.sqlite3")
                let copiedDatabase = try streamCopyForPreflight(
                    from: databaseURL,
                    to: stagedDatabaseURL,
                    maximumBytes: maximumBytes,
                    deadline: deadline
                )
                guard copiedDatabase == before.database else {
                    throw VerifiedMigrationBackupError.creationFailed(
                        "SQLite database changed while it was staged"
                    )
                }
                if let writeAheadLog = before.writeAheadLog {
                    let copiedWAL = try streamCopyForPreflight(
                        from: URL(fileURLWithPath: databaseURL.path + "-wal"),
                        to: URL(fileURLWithPath: stagedDatabaseURL.path + "-wal"),
                        maximumBytes: maximumBytes,
                        deadline: deadline
                    )
                    guard copiedWAL == writeAheadLog else {
                        throw VerifiedMigrationBackupError.creationFailed(
                            "SQLite write-ahead log changed while it was staged"
                        )
                    }
                }
                let afterCopy = try sqliteSourceState(
                    databaseURL: databaseURL,
                    maximumBytes: maximumBytes,
                    deadline: deadline
                )
                guard before.hasSameDurableContent(as: afterCopy) else {
                    throw VerifiedMigrationBackupError.creationFailed(
                        "SQLite source changed while it was staged"
                    )
                }

                var staged: OpaquePointer?
                let openResult = sqlite3_open_v2(
                    stagedDatabaseURL.path,
                    &staged,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                    nil
                )
                guard openResult == SQLITE_OK, let staged else {
                    let error = staged.map {
                        preflightSQLiteError(
                            "SQLite private preflight copy could not be opened",
                            result: openResult,
                            database: $0
                        )
                    } ?? VerifiedMigrationBackupError.invalidSource(
                        "SQLite private preflight copy could not be opened"
                    )
                    if let staged { sqlite3_close(staged) }
                    throw error
                }
                defer { sqlite3_close_v2(staged) }
                sqlite3_busy_timeout(staged, 5_000)
                let inspectionError: Error?
                do {
                    try withSQLiteProgressDeadline(database: staged, deadline: deadline) {
                        let quickCheck = try preflightSQLiteText("PRAGMA quick_check;", database: staged)
                        guard quickCheck?.lowercased() == "ok" else {
                            throw VerifiedMigrationBackupError.corruptSource(
                                "SQLite private preflight copy failed quick_check: "
                                    + (quickCheck ?? "no result")
                            )
                        }
                        try inspect(SQLitePreflightDatabase(
                            database: staged,
                            sourceHasWriteAheadLog: before.writeAheadLog != nil
                        ))
                    }
                    inspectionError = nil
                } catch {
                    inspectionError = error
                }

                let afterInspection = try sqliteSourceState(
                    databaseURL: databaseURL,
                    maximumBytes: maximumBytes,
                    deadline: deadline
                )
                guard before.hasSameDurableContent(as: afterInspection) else {
                    throw VerifiedMigrationBackupError.creationFailed(
                        "SQLite source changed during private preflight inspection"
                    )
                }
                if let inspectionError { throw inspectionError }
                return
            } catch let error as VerifiedMigrationBackupError {
                switch error {
                case .creationFailed(let detail) where detail.contains("changed")
                    || detail.contains("appeared"):
                    lastInstability = error
                    continue
                default:
                    throw error
                }
            }
        }
        throw lastInstability ?? VerifiedMigrationBackupError.creationFailed(
            "SQLite source did not become stable before the preflight deadline"
        )
    }

    static func registerOpenDatabase(at databaseURL: URL) throws -> SQLiteOpenRegistration {
        let identity = try sqliteFileIdentity(at: databaseURL)
        openRegistrationLock.lock()
        openRegistrationCounts[identity, default: 0] += 1
        openRegistrationLock.unlock()
        return SQLiteOpenRegistration(identity: identity)
    }

    static func unregisterOpenDatabase(_ registration: SQLiteOpenRegistration?) {
        guard let registration else { return }
        openRegistrationLock.lock()
        if let count = openRegistrationCounts[registration.identity] {
            if count <= 1 {
                openRegistrationCounts.removeValue(forKey: registration.identity)
            } else {
                openRegistrationCounts[registration.identity] = count - 1
            }
        }
        openRegistrationLock.unlock()
    }

    /// Proves that schema version zero means a genuinely empty SQLite database.
    /// Call immediately after opening the connection and before journal-mode or DDL writes.
    static func requireEmptySQLiteSchemaWhenUnversioned(
        database: OpaquePointer,
        reportedVersion: Int
    ) throws {
        guard reportedVersion >= 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite schema version cannot be negative"
            )
        }
        guard reportedVersion == 0 else { return }

        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM main.sqlite_master LIMIT 1;"
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw VerifiedMigrationBackupError.invalidSource(
                "unversioned SQLite schema could not be inspected: "
                    + String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return
        case SQLITE_ROW:
            throw VerifiedMigrationBackupError.invalidSource(
                "unversioned SQLite database is not empty"
            )
        default:
            throw VerifiedMigrationBackupError.invalidSource(
                "unversioned SQLite schema could not be inspected: "
                    + String(cString: sqlite3_errmsg(database))
            )
        }
    }

    public static func activeManifestURL(for sourceURL: URL) -> URL {
        sourceURL.appendingPathExtension("migration-manifest.json")
    }

    public static func archivedManifestURL(
        for backupURL: URL,
        targetVersion: Int
    ) -> URL {
        backupURL.appendingPathExtension("to-v\(targetVersion).manifest.json")
    }

    /// Writes a bounded owner-only file or verifies an identical fixed artifact already exists.
    public static func writeFile(
        _ data: Data,
        to destinationURL: URL,
        maximumBytes: Int
    ) throws -> VerifiedMigrationBackupMetadata {
        guard maximumBytes > 0, !data.isEmpty, data.count <= maximumBytes else {
            throw VerifiedMigrationBackupError.invalidSource(
                "file data is empty or exceeds the migration backup limit"
            )
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let existing = try boundedRegularFileData(
                at: destinationURL,
                maximumBytes: maximumBytes
            )
            guard existing == data else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "existing fixed migration artifact differs from the requested bytes"
                )
            }
            try hardenAndVerifyPermissions(at: destinationURL)
            return try metadata(for: destinationURL)
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = try temporarySibling(of: destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try writeOwnerOnlyFile(data, to: temporaryURL)
        try install(temporaryURL: temporaryURL, backupURL: destinationURL)
        let installed = try boundedRegularFileData(
            at: destinationURL,
            maximumBytes: maximumBytes
        )
        guard installed == data else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "installed fixed migration artifact differs from the requested bytes"
            )
        }
        try hardenAndVerifyPermissions(at: destinationURL)
        return try metadata(for: destinationURL)
    }

    /// Selects one of a bounded set of immutable file-migration lineages. The preferred
    /// filenames remain the first lineage; later lineages insert a deterministic suffix before
    /// the extension. A source already captured by a lineage reuses its exact artifacts, while
    /// occupied lineages with different source bytes are never overwritten.
    public static func prepareFileMigrationArtifacts(
        sourceURL: URL,
        preferredBackupURL: URL,
        preferredTargetArtifactURL: URL,
        maximumBytes: Int,
        maximumLineages: Int,
        targetDataForBackup: (VerifiedMigrationBackupMetadata) throws -> Data
    ) throws -> (
        backup: VerifiedMigrationBackupMetadata,
        targetArtifact: VerifiedMigrationBackupMetadata
    ) {
        guard maximumBytes > 0,
              maximumLineages > 0,
              maximumLineages <= 32 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "file migration lineage limits are invalid"
            )
        }
        try requireSameDirectory(sourceURL, preferredBackupURL)
        try requireSameDirectory(sourceURL, preferredTargetArtifactURL)
        guard preferredBackupURL.lastPathComponent
                != preferredTargetArtifactURL.lastPathComponent else {
            throw VerifiedMigrationBackupError.invalidSource(
                "file migration backup and target artifact must be distinct"
            )
        }

        let source = try boundedRegularFileData(
            at: sourceURL,
            maximumBytes: maximumBytes
        )
        for lineage in 1...maximumLineages {
            let backupURL = fileMigrationLineageURL(
                preferredURL: preferredBackupURL,
                lineage: lineage
            )
            let targetArtifactURL = fileMigrationLineageURL(
                preferredURL: preferredTargetArtifactURL,
                lineage: lineage
            )
            if FileManager.default.fileExists(atPath: backupURL.path) {
                let existing = try boundedRegularFileData(
                    at: backupURL,
                    maximumBytes: maximumBytes
                )
                guard existing == source else { continue }
            } else if FileManager.default.fileExists(atPath: targetArtifactURL.path) {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "file migration target artifact exists without its source lineage"
                )
            }

            let backup = try copyFile(
                from: sourceURL,
                to: backupURL,
                maximumBytes: maximumBytes
            )
            let targetData = try targetDataForBackup(backup)
            let targetArtifact = try writeFile(
                targetData,
                to: targetArtifactURL,
                maximumBytes: maximumBytes
            )
            return (backup: backup, targetArtifact: targetArtifact)
        }
        throw VerifiedMigrationBackupError.reconciliationFailed(
            "all bounded file migration lineages are occupied by different sources"
        )
    }

    /// Persists the durable precondition for an in-place migration.
    /// Call only while holding the migration lock and after the source backup is verified.
    public static func prepareMigrationManifest(
        sourceURL: URL,
        backup: VerifiedMigrationBackupMetadata,
        sourceVersion: Int,
        targetVersion: Int,
        storageKind: VerifiedMigrationStorageKind,
        targetArtifact: VerifiedMigrationBackupMetadata? = nil,
        preparedAt: Date = Date()
    ) throws -> VerifiedMigrationBackupManifest {
        guard sourceVersion >= 0,
              targetVersion > sourceVersion,
              sourceVersion > 0 || storageKind == .sqlite else {
            throw VerifiedMigrationBackupError.invalidSource(
                "migration source version must be nonnegative and lower than the target version"
            )
        }
        try requireSameDirectory(sourceURL, backup.url)
        let verifiedBackup = try metadata(
            for: backup.url,
            maximumBytes: backup.bytes
        )
        guard verifiedBackup.sha256 == backup.sha256,
              verifiedBackup.bytes == backup.bytes,
              backup.bytes > 0 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "migration backup metadata changed before manifest preparation"
            )
        }

        let verifiedTargetArtifact: VerifiedMigrationBackupMetadata?
        if let targetArtifact {
            try requireSameDirectory(sourceURL, targetArtifact.url)
            let verified = try metadata(
                for: targetArtifact.url,
                maximumBytes: targetArtifact.bytes
            )
            guard verified.sha256 == targetArtifact.sha256,
                  verified.bytes == targetArtifact.bytes,
                  verified.bytes > 0 else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "migration target artifact metadata changed before manifest preparation"
                )
            }
            verifiedTargetArtifact = verified
        } else {
            verifiedTargetArtifact = nil
        }
        guard storageKind == .file || verifiedTargetArtifact == nil else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite migration preparation cannot reference a file target artifact"
            )
        }
        guard storageKind == .sqlite || verifiedTargetArtifact != nil else {
            throw VerifiedMigrationBackupError.invalidSource(
                "file migration preparation requires a verified target artifact"
            )
        }

        let migrationID = migrationIdentifier(
            sourceFilename: sourceURL.lastPathComponent,
            backupFilename: backup.url.lastPathComponent,
            sourceVersion: sourceVersion,
            targetVersion: targetVersion,
            storageKind: storageKind,
            sourceSHA256: backup.sha256,
            sourceBytes: backup.bytes,
            targetSHA256: verifiedTargetArtifact?.sha256,
            targetBytes: verifiedTargetArtifact?.bytes
        )
        var desired = VerifiedMigrationBackupManifest(
            schemaVersion: manifestSchemaVersion,
            migrationID: migrationID,
            state: .prepared,
            storageKind: storageKind,
            sourceFilename: sourceURL.lastPathComponent,
            sourceVersion: sourceVersion,
            sourceSHA256: backup.sha256,
            sourceBytes: backup.bytes,
            backupFilename: backup.url.lastPathComponent,
            backupSHA256: backup.sha256,
            backupBytes: backup.bytes,
            targetVersion: targetVersion,
            targetSHA256: verifiedTargetArtifact?.sha256,
            targetBytes: verifiedTargetArtifact?.bytes,
            targetArtifactFilename: verifiedTargetArtifact?.url.lastPathComponent,
            rollbackInstructions: rollbackInstructions(
                sourceFilename: sourceURL.lastPathComponent,
                backupFilename: backup.url.lastPathComponent,
                sourceVersion: sourceVersion,
                sha256: backup.sha256,
                bytes: backup.bytes,
                storageKind: storageKind
            ),
            preparedAt: ISO8601.string(from: preparedAt),
            completedAt: nil
        )
        try validateManifest(desired)

        if let existing = try reconcileMigrationManifest(
            sourceURL: sourceURL,
            observedVersion: sourceVersion,
            allowCompletedFileLineageRestart: storageKind == .file
        ) {
            if existing.state == .prepared {
                guard hasSameMigrationIdentity(existing, desired) else {
                    throw VerifiedMigrationBackupError.reconciliationFailed(
                        "an unrelated prepared migration already owns this source"
                    )
                }
                return existing
            }
            if existing.sourceVersion == sourceVersion {
                if hasSameMigrationIdentity(existing, desired) {
                    desired = preparedManifest(
                        from: desired,
                        preparedAt: existing.preparedAt
                    )
                } else if existing.storageKind == .sqlite,
                          desired.storageKind == .sqlite,
                          existing.backupFilename != desired.backupFilename,
                          existing.sourceSHA256 != desired.sourceSHA256 {
                    // A restored old-format database may receive legitimate writes before it is
                    // migrated again. Keep the prior immutable lineage and start a bounded new
                    // lineage instead of overwriting its recovery artifact.
                } else {
                    throw VerifiedMigrationBackupError.reconciliationFailed(
                        "completed migration lineage conflicts with the restored source"
                    )
                }
            } else if existing.targetVersion != sourceVersion {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "the completed migration manifest does not precede this source version"
                )
            }
        }

        let activeURL = activeManifestURL(for: sourceURL)
        try writeManifestReplacing(desired, to: activeURL)
        let installed = try requireManifest(at: activeURL)
        guard installed == desired else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "installed prepared migration manifest differs from the requested state"
            )
        }
        try validateManifestArtifacts(installed, sourceURL: sourceURL)
        return installed
    }

    /// Reconciles a prior durable manifest without guessing about intermediate source versions.
    /// A prepared target is completed only when the caller supplies a verified logical target.
    @discardableResult
    public static func reconcileMigrationManifest(
        sourceURL: URL,
        observedVersion: Int,
        targetMetadata: VerifiedMigrationBackupMetadata? = nil,
        completedAt: Date = Date(),
        allowCompletedFileLineageRestart: Bool = false
    ) throws -> VerifiedMigrationBackupManifest? {
        let activeURL = activeManifestURL(for: sourceURL)
        guard let manifest = try readManifestIfPresent(at: activeURL) else { return nil }
        try validateManifestArtifacts(manifest, sourceURL: sourceURL)

        switch manifest.state {
        case .prepared:
            if observedVersion == manifest.sourceVersion {
                if manifest.storageKind == .file {
                    let liveSource = try metadata(
                        for: sourceURL,
                        maximumBytes: manifest.sourceBytes
                    )
                    guard liveSource.sha256 == manifest.sourceSHA256,
                          liveSource.bytes == manifest.sourceBytes else {
                        throw VerifiedMigrationBackupError.reconciliationFailed(
                            "prepared file migration source no longer matches its verified backup"
                        )
                    }
                }
                return manifest
            }
            if observedVersion == manifest.targetVersion {
                if manifest.storageKind == .sqlite, targetMetadata == nil {
                    return manifest
                }
                let verifiedTarget = try completionMetadata(
                    for: manifest,
                    sourceURL: sourceURL,
                    supplied: targetMetadata
                )
                return try completeMigrationManifest(
                    sourceURL: sourceURL,
                    preparedManifest: manifest,
                    observedVersion: observedVersion,
                    targetMetadata: verifiedTarget,
                    completedAt: completedAt
                )
            }
        case .completed:
            try archiveCompletedManifest(manifest, sourceURL: sourceURL)
            if observedVersion == manifest.targetVersion {
                return manifest
            }
            if observedVersion == manifest.sourceVersion {
                if manifest.storageKind == .file {
                    let liveSource = try metadata(
                        for: sourceURL
                    )
                    if liveSource.sha256 != manifest.sourceSHA256
                        || liveSource.bytes != manifest.sourceBytes {
                        if allowCompletedFileLineageRestart {
                            return nil
                        }
                        throw VerifiedMigrationBackupError.reconciliationFailed(
                            "restored file migration source does not match its verified backup"
                        )
                    }
                }
                return manifest
            }
        }
        throw VerifiedMigrationBackupError.reconciliationFailed(
            "manifest versions \(manifest.sourceVersion)->\(manifest.targetVersion) do not match observed version \(observedVersion)"
        )
    }

    @discardableResult
    public static func completeMigrationManifest(
        sourceURL: URL,
        preparedManifest: VerifiedMigrationBackupManifest,
        observedVersion: Int,
        targetMetadata: VerifiedMigrationBackupMetadata,
        completedAt: Date = Date()
    ) throws -> VerifiedMigrationBackupManifest {
        guard observedVersion == preparedManifest.targetVersion else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration completion requires the exact target schema version"
            )
        }
        let activeURL = activeManifestURL(for: sourceURL)
        let current = try requireManifest(at: activeURL)
        guard hasSameMigrationIdentity(current, preparedManifest) else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "active migration manifest identity changed before completion"
            )
        }
        if current.state == .completed {
            return try archiveCompletedManifest(current, sourceURL: sourceURL)
        }
        let verifiedTarget = try completionMetadata(
            for: current,
            sourceURL: sourceURL,
            supplied: targetMetadata
        )
        let completed = VerifiedMigrationBackupManifest(
            schemaVersion: current.schemaVersion,
            migrationID: current.migrationID,
            state: .completed,
            storageKind: current.storageKind,
            sourceFilename: current.sourceFilename,
            sourceVersion: current.sourceVersion,
            sourceSHA256: current.sourceSHA256,
            sourceBytes: current.sourceBytes,
            backupFilename: current.backupFilename,
            backupSHA256: current.backupSHA256,
            backupBytes: current.backupBytes,
            targetVersion: current.targetVersion,
            targetSHA256: verifiedTarget.sha256,
            targetBytes: verifiedTarget.bytes,
            targetArtifactFilename: current.targetArtifactFilename,
            rollbackInstructions: current.rollbackInstructions,
            preparedAt: current.preparedAt,
            completedAt: ISO8601.string(from: completedAt)
        )
        try validateManifest(completed)
        let archived = try archiveCompletedManifest(completed, sourceURL: sourceURL)
        try writeManifestReplacing(archived, to: activeURL)
        let installed = try requireManifest(at: activeURL)
        guard installed == archived else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "installed completed migration manifest differs from the requested state"
            )
        }
        return installed
    }

    /// Installs the exact durable target artifact for a prepared or explicitly restored
    /// file migration. The verified source backup remains untouched for rollback.
    @discardableResult
    public static func installFileMigrationTarget(
        sourceURL: URL,
        manifest: VerifiedMigrationBackupManifest
    ) throws -> VerifiedMigrationBackupMetadata {
        guard manifest.storageKind == .file,
              observedSourceCanInstallFileTarget(manifest.state),
              let targetArtifactFilename = manifest.targetArtifactFilename,
              let targetBytes = manifest.targetBytes,
              max(targetBytes, manifest.sourceBytes) <= UInt64(Int.max) else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "file migration target installation metadata is invalid"
            )
        }
        try validateManifestArtifacts(manifest, sourceURL: sourceURL)
        let liveSource = try metadata(
            for: sourceURL,
            maximumBytes: manifest.sourceBytes
        )
        guard liveSource.sha256 == manifest.sourceSHA256,
              liveSource.bytes == manifest.sourceBytes else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "file migration source changed before target installation"
            )
        }
        let targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            targetArtifactFilename
        )
        let targetData = try boundedRegularFileData(
            at: targetURL,
            maximumBytes: Int(targetBytes)
        )
        guard UInt64(targetData.count) == targetBytes,
              JSONSupport.sha256Hex(targetData) == manifest.targetSHA256 else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "file migration target artifact changed before installation"
            )
        }
        try replaceOwnerOnlyFile(
            targetData,
            at: sourceURL,
            maximumBytes: Int(max(targetBytes, manifest.sourceBytes))
        )
        let installed = try metadata(for: sourceURL, maximumBytes: targetBytes)
        guard installed.sha256 == manifest.targetSHA256,
              installed.bytes == targetBytes else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "installed file migration target differs from its verified artifact"
            )
        }
        return installed
    }

    static func logicalSQLiteMetadata(
        database: OpaquePointer,
        sourceURL: URL,
        expectedVersion: Int,
        versionQuery: String
    ) throws -> VerifiedMigrationBackupMetadata {
        let root = try resetTemporaryDirectory(
            kind: "migration-target",
            key: sourceURL.standardizedFileURL.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        return try snapshotSQLite(
            database: database,
            to: root.appendingPathComponent("target.sqlite3"),
            expectedVersion: expectedVersion,
            versionQuery: versionQuery
        )
    }

    /// Captures the exact live logical source while the caller holds SQLite's write boundary,
    /// then durably prepares the manifest before any schema DDL runs.
    static func prepareSQLiteMigrationAtWriteBoundary(
        database: OpaquePointer,
        sourceURL: URL,
        backupURL: URL,
        sourceVersion: Int,
        targetVersion: Int,
        versionQuery: String
    ) throws -> VerifiedMigrationBackupManifest {
        guard sqlite3_get_autocommit(database) == 0 else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite source backup requires an active write transaction"
            )
        }
        try requireSQLiteMainFileUnmoved(
            database: database,
            sourceURL: sourceURL,
            purpose: "migration backup writer entry"
        )
        var reader: OpaquePointer?
        let opened = sqlite3_open_v2(
            sourceURL.path,
            &reader,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let reader else {
            if let reader { sqlite3_close(reader) }
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite source could not be reopened at the write boundary"
            )
        }
        defer { sqlite3_close(reader) }
        sqlite3_busy_timeout(reader, 5_000)
        try requireSQLiteMainFileUnmoved(
            database: database,
            sourceURL: sourceURL,
            purpose: "migration backup reader open"
        )
        try requireSQLiteMainFileUnmoved(
            database: reader,
            sourceURL: sourceURL,
            purpose: "migration backup reader open"
        )
        let backup = try snapshotSQLite(
            database: reader,
            to: backupURL,
            expectedVersion: sourceVersion,
            versionQuery: versionQuery,
            allowAlternateLineages: true
        )
        try requireSQLiteMainFileUnmoved(
            database: reader,
            sourceURL: sourceURL,
            purpose: "migration backup snapshot completion"
        )
        try requireSQLiteMainFileUnmoved(
            database: database,
            sourceURL: sourceURL,
            purpose: "migration backup snapshot completion"
        )
        return try prepareMigrationManifest(
            sourceURL: sourceURL,
            backup: backup,
            sourceVersion: sourceVersion,
            targetVersion: targetVersion,
            storageKind: .sqlite
        )
    }

    /// Fails closed when an open SQLite connection no longer owns the main file currently
    /// reachable through its expected pathname. Call this at narrow durable-write boundaries.
    static func requireSQLiteMainFileUnmoved(
        database: OpaquePointer,
        sourceURL: URL,
        purpose: String
    ) throws {
        let normalizedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceURL.isFileURL,
              !normalizedPurpose.isEmpty,
              normalizedPurpose.utf8.count <= 256 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite main-file movement check arguments are invalid"
            )
        }
        guard let filename = sqlite3_db_filename(database, "main"), filename.pointee != 0 else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite main database filename is unavailable during \(normalizedPurpose)"
            )
        }
        let connectedURL = URL(fileURLWithPath: String(cString: filename))
        let connectedPath = connectedURL.standardizedFileURL.resolvingSymlinksInPath().path
        let expectedPath = sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard connectedPath == expectedPath else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite main database path differs from the expected source during "
                    + normalizedPurpose
            )
        }

        let identityBefore = try sqliteFileIdentity(at: sourceURL)
        var hasMoved: Int32 = 0
        let controlResult = sqlite3_file_control(
            database,
            "main",
            SQLITE_FCNTL_HAS_MOVED,
            &hasMoved
        )
        guard controlResult == SQLITE_OK else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite main file moved or was replaced, or its identity could not be verified "
                    + "during \(normalizedPurpose) "
                    + "with result \(controlResult)"
            )
        }
        let identityAfter = try sqliteFileIdentity(at: sourceURL)
        guard hasMoved == 0, identityBefore == identityAfter else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite main file moved or was replaced during \(normalizedPurpose)"
            )
        }
    }

    /// Writes the lineage marker in the same SQLite transaction as the target schema version.
    static func recordSQLiteMigrationReceipt(
        database: OpaquePointer,
        sourceURL: URL,
        manifest: VerifiedMigrationBackupManifest
    ) throws {
        guard manifest.storageKind == .sqlite, manifest.state == .prepared else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite migration receipt requires a prepared SQLite manifest"
            )
        }
        try validateManifestArtifacts(manifest, sourceURL: sourceURL)
        try sqliteExecute(
            """
            CREATE TABLE IF NOT EXISTS forge_migration_receipts(
              migration_id TEXT PRIMARY KEY,
              receipt_schema_version INTEGER NOT NULL CHECK(receipt_schema_version=1),
              source_filename TEXT NOT NULL,
              backup_filename TEXT NOT NULL,
              source_version INTEGER NOT NULL,
              target_version INTEGER NOT NULL,
              source_sha256 TEXT NOT NULL,
              source_bytes INTEGER NOT NULL
            ) WITHOUT ROWID;
            """,
            database: database
        )
        var statement: OpaquePointer?
        let sql = """
        INSERT OR IGNORE INTO forge_migration_receipts(
          migration_id,receipt_schema_version,source_filename,backup_filename,
          source_version,target_version,source_sha256,source_bytes
        ) VALUES(?,1,?,?,?,?,?,?);
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite migration receipt insert could not be prepared"
            )
        }
        defer { sqlite3_finalize(statement) }
        try bindMigrationReceipt(manifest, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite migration receipt could not be recorded: "
                    + String(cString: sqlite3_errmsg(database))
            )
        }
        _ = try requireSQLiteMigrationReceipt(
            database: database,
            sourceURL: sourceURL,
            manifest: manifest,
            validateArtifacts: false,
            reconcileArchivedCompletion: false
        )
    }

    /// Requires the exact receipt written by the source-to-target transaction. Schema version
    /// alone is insufficient because an unrelated current-version database can be substituted.
    @discardableResult
    static func requireSQLiteMigrationReceipt(
        database: OpaquePointer,
        sourceURL: URL,
        manifest: VerifiedMigrationBackupManifest
    ) throws -> VerifiedMigrationBackupManifest {
        try requireSQLiteMigrationReceipt(
            database: database,
            sourceURL: sourceURL,
            manifest: manifest,
            validateArtifacts: true,
            reconcileArchivedCompletion: true
        )
    }

    /// Ensures SQLite's committed migration is checkpointed before completed evidence is fsynced.
    static func checkpointSQLiteMigration(
        database: OpaquePointer,
        sourceURL: URL
    ) throws {
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        guard result == SQLITE_OK,
              logFrames < 0 || checkpointedFrames >= logFrames else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite migration checkpoint did not complete: result \(result), "
                    + "frames \(checkpointedFrames)/\(logFrames)"
            )
        }
        try synchronizeFile(at: sourceURL)
        try synchronizeDirectory(at: sourceURL.deletingLastPathComponent())
    }

    /// Copies one bounded file exactly and fails closed if a prior recovery artifact differs.
    public static func copyFile(
        from sourceURL: URL,
        to backupURL: URL,
        maximumBytes: Int
    ) throws -> VerifiedMigrationBackupMetadata {
        guard maximumBytes > 0 else {
            throw VerifiedMigrationBackupError.invalidSource("maximum byte count must be positive")
        }
        let source = try boundedRegularFileData(at: sourceURL, maximumBytes: maximumBytes)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let existing = try boundedRegularFileData(at: backupURL, maximumBytes: maximumBytes)
            guard existing == source else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "existing recovery artifact does not match the migration source"
                )
            }
            try hardenAndVerifyPermissions(at: backupURL)
            return try metadata(for: backupURL)
        }

        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = try temporarySibling(of: backupURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try writeOwnerOnlyFile(source, to: temporaryURL)
            let written = try boundedRegularFileData(at: temporaryURL, maximumBytes: maximumBytes)
            guard written == source else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "recovery artifact bytes differ from the migration source"
                )
            }
            try install(temporaryURL: temporaryURL, backupURL: backupURL)
        } catch let error as VerifiedMigrationBackupError {
            throw error
        } catch {
            throw VerifiedMigrationBackupError.creationFailed(error.localizedDescription)
        }

        let installed = try boundedRegularFileData(at: backupURL, maximumBytes: maximumBytes)
        guard installed == source else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "installed recovery artifact differs from the migration source"
            )
        }
        try hardenAndVerifyPermissions(at: backupURL)
        return try metadata(for: backupURL)
    }

    /// Streams one stable owner-controlled file into a durable, owner-only recovery artifact.
    /// This avoids loading a potentially large corrupt database into memory merely to preserve it.
    static func preserveStableFile(
        from sourceURL: URL,
        to backupURL: URL,
        maximumBytes: UInt64 = maximumSQLiteBackupBytes,
        timeoutSeconds: TimeInterval = sqliteBackupDeadline
    ) throws -> VerifiedMigrationBackupMetadata {
        guard maximumBytes > 0, timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "recovery artifact byte limit and deadline must be positive"
            )
        }
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = try temporarySibling(of: backupURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let source = try streamCopyForPreflight(
            from: sourceURL,
            to: temporaryURL,
            maximumBytes: maximumBytes,
            deadline: deadline
        )
        let staged = try metadata(for: temporaryURL, allowEmpty: true)
        guard staged.bytes == source.bytes, staged.sha256 == source.sha256 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "staged recovery artifact differs from the stable source"
            )
        }
        try install(temporaryURL: temporaryURL, backupURL: backupURL)
        try hardenAndVerifyPermissions(at: backupURL)
        let installed = try metadata(for: backupURL, allowEmpty: true)
        guard installed.bytes == source.bytes, installed.sha256 == source.sha256 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "installed recovery artifact differs from the stable source"
            )
        }
        return installed
    }

    /// Uses SQLite's online-backup API so WAL and hot-journal content are included.
    static func snapshotSQLite(
        database: OpaquePointer,
        to backupURL: URL,
        expectedVersion: Int,
        versionQuery: String,
        maximumBytes: UInt64 = maximumSQLiteBackupBytes,
        timeoutSeconds: TimeInterval = sqliteBackupDeadline,
        allowAlternateLineages: Bool = false
    ) throws -> VerifiedMigrationBackupMetadata {
        guard expectedVersion >= 0, !versionQuery.isEmpty,
              maximumBytes > 0,
              timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source version, version query, byte limit, and deadline are invalid"
            )
        }
        let deadlineUptime = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let pageSize = try sqlitePositiveUInt64("PRAGMA page_size;", database: database)
        let sourcePageCount = try sqlitePositiveUInt64("PRAGMA page_count;", database: database)
        let (sourceBytes, sourceSizeOverflowed) = pageSize.multipliedReportingOverflow(
            by: sourcePageCount
        )
        guard !sourceSizeOverflowed, sourceBytes <= maximumBytes else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source exceeds the migration backup byte limit"
            )
        }
        let maximumPageCount = maximumBytes / pageSize
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = try temporarySibling(of: backupURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let creationDescriptor = try createOwnerOnlyFile(at: temporaryURL)
        guard Darwin.close(creationDescriptor) == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "owner-only SQLite recovery artifact could not be closed"
            )
        }

        var destination: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let opened = sqlite3_open_v2(temporaryURL.path, &destination, flags, nil)
        guard opened == SQLITE_OK, let destination else {
            let detail = destination.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite result \(opened)"
            if let destination { sqlite3_close(destination) }
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite recovery artifact could not be opened: \(detail)"
            )
        }
        var destinationIsOpen = true
        defer {
            if destinationIsOpen { sqlite3_close(destination) }
        }
        try hardenAndVerifyPermissions(at: temporaryURL)
        sqlite3_busy_timeout(destination, 5_000)
        guard let transfer = sqlite3_backup_init(destination, "main", database, "main") else {
            throw VerifiedMigrationBackupError.creationFailed(
                String(cString: sqlite3_errmsg(destination))
            )
        }

        var stepResult = SQLITE_OK
        var exceededByteLimit = false
        var exceededDeadline = false
        repeat {
            guard ProcessInfo.processInfo.systemUptime < deadlineUptime else {
                exceededDeadline = true
                break
            }
            stepResult = sqlite3_backup_step(transfer, sqliteBackupPageBatch)
            let reportedPageCount = sqlite3_backup_pagecount(transfer)
            if reportedPageCount < 0
                || UInt64(reportedPageCount) > maximumPageCount {
                exceededByteLimit = true
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadlineUptime {
                exceededDeadline = true
                break
            }
            if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
                let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    exceededDeadline = true
                    break
                }
                sqlite3_sleep(Int32(min(25, max(1, Int(remaining * 1_000)))))
            }
        } while stepResult == SQLITE_OK || stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED
        let finishResult = sqlite3_backup_finish(transfer)
        if exceededByteLimit {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source grew beyond the migration backup byte limit"
            )
        }
        if exceededDeadline {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite online backup did not complete before its deadline"
            )
        }
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite online backup failed with result \(stepResult)"
            )
        }
        try sqliteExecute("PRAGMA journal_mode=DELETE;", database: destination)
        guard sqlite3_close(destination) == SQLITE_OK else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite recovery artifact could not be closed"
            )
        }
        destinationIsOpen = false

        let snapshot = try verifySQLiteBackup(
            at: temporaryURL,
            expectedVersion: expectedVersion,
            versionQuery: versionQuery,
            maximumBytes: maximumBytes,
            deadlineUptime: deadlineUptime
        )
        try synchronizeFile(at: temporaryURL)
        try hardenAndVerifyPermissions(at: temporaryURL)
        let lineageCount = allowAlternateLineages
            ? maximumSQLiteBackupLineagesPerSourceVersion
            : 1
        for slot in 1...lineageCount {
            let candidateURL = sqliteBackupLineageURL(
                preferredURL: backupURL,
                slot: slot
            )
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                let existing = try verifySQLiteBackup(
                    at: candidateURL,
                    expectedVersion: expectedVersion,
                    versionQuery: versionQuery,
                    maximumBytes: maximumBytes,
                    deadlineUptime: deadlineUptime
                )
                if existing.bytes == snapshot.bytes,
                   existing.sha256 == snapshot.sha256 {
                    return existing
                }
                continue
            }
            do {
                try install(temporaryURL: temporaryURL, backupURL: candidateURL)
            } catch let error as VerifiedMigrationBackupError {
                throw error
            } catch {
                throw VerifiedMigrationBackupError.creationFailed(error.localizedDescription)
            }
            let installed = try verifySQLiteBackup(
                at: candidateURL,
                expectedVersion: expectedVersion,
                versionQuery: versionQuery,
                maximumBytes: maximumBytes,
                deadlineUptime: deadlineUptime
            )
            guard installed.bytes == snapshot.bytes,
                  installed.sha256 == snapshot.sha256 else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "installed SQLite recovery artifact differs from the current logical source"
                )
            }
            return installed
        }
        throw VerifiedMigrationBackupError.verificationFailed(
            "bounded SQLite recovery lineage slots are exhausted for this source version"
        )
    }

    private static func sqliteBackupLineageURL(
        preferredURL: URL,
        slot: Int
    ) -> URL {
        guard slot > 1 else { return preferredURL }
        let extensionName = preferredURL.pathExtension
        let base = extensionName.isEmpty
            ? preferredURL
            : preferredURL.deletingPathExtension()
        let filename = base.lastPathComponent + ".lineage-\(slot)"
            + (extensionName.isEmpty ? "" : ".\(extensionName)")
        return preferredURL.deletingLastPathComponent().appendingPathComponent(
            filename,
            isDirectory: false
        )
    }

    private static func verifySQLiteBackup(
        at url: URL,
        expectedVersion: Int,
        versionQuery: String,
        maximumBytes: UInt64,
        deadlineUptime: TimeInterval
    ) throws -> VerifiedMigrationBackupMetadata {
        guard ProcessInfo.processInfo.systemUptime < deadlineUptime else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite recovery artifact verification exceeded its deadline"
            )
        }
        let attributes = try regularFileAttributes(at: url)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value > 0,
              size.uint64Value <= maximumBytes else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact is empty or exceeds its byte limit"
            )
        }
        let validationDescriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard validationDescriptor >= 0 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact could not be opened without following links"
            )
        }
        defer { _ = Darwin.close(validationDescriptor) }
        let validatedStatus = try validatedOwnerControlledDescriptor(
            validationDescriptor,
            purpose: "SQLite recovery artifact"
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let opened = sqlite3_open_v2(url.path, &database, flags, nil)
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact cannot be reopened"
            )
        }
        defer { sqlite3_close(database) }
        let remainingMilliseconds = max(
            1,
            min(
                5_000,
                Int((deadlineUptime - ProcessInfo.processInfo.systemUptime) * 1_000)
            )
        )
        sqlite3_busy_timeout(database, Int32(remainingMilliseconds))
        var openedStatus = stat()
        let statusResult = url.path.withCString { Darwin.lstat($0, &openedStatus) }
        guard statusResult == 0,
              openedStatus.st_dev == validatedStatus.st_dev,
              openedStatus.st_ino == validatedStatus.st_ino else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact changed while it was opened"
            )
        }
        try withSQLiteProgressDeadline(database: database, deadline: deadlineUptime) {
            let integrity = try sqliteText("PRAGMA quick_check;", database: database)
            guard integrity?.lowercased() == "ok" else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "SQLite recovery artifact failed quick_check"
                )
            }
            let version = try sqliteInt(versionQuery, database: database)
            guard version == expectedVersion else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "SQLite recovery artifact has schema version \(version.map(String.init) ?? "missing")"
                )
            }
        }
        try hardenAndVerifyPermissions(at: url)
        return try metadata(
            for: url,
            origin: .sqliteSnapshot,
            deadlineUptime: deadlineUptime
        )
    }

    fileprivate static func preflightSQLiteInt(
        _ sql: String,
        database: OpaquePointer
    ) throws -> Int? {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw preflightSQLiteError(
                "SQLite preflight query could not be prepared",
                result: prepareResult,
                database: database
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { return nil }
        guard stepResult == SQLITE_ROW else {
            throw preflightSQLiteError(
                "SQLite preflight query could not be evaluated",
                result: stepResult,
                database: database
            )
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func preflightSQLiteText(
        _ sql: String,
        database: OpaquePointer
    ) throws -> String? {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw preflightSQLiteError(
                "SQLite preflight query could not be prepared",
                result: prepareResult,
                database: database
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { return nil }
        guard stepResult == SQLITE_ROW else {
            throw preflightSQLiteError(
                "SQLite preflight query could not be evaluated",
                result: stepResult,
                database: database
            )
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private static func preflightSQLiteError(
        _ detail: String,
        result: Int32,
        database: OpaquePointer
    ) -> VerifiedMigrationBackupError {
        let resultCode = result & 0xFF
        let databaseCode = sqlite3_errcode(database) & 0xFF
        let message = detail + ": " + String(cString: sqlite3_errmsg(database))
        if resultCode == SQLITE_CORRUPT || resultCode == SQLITE_NOTADB
            || databaseCode == SQLITE_CORRUPT || databaseCode == SQLITE_NOTADB {
            return .corruptSource(message)
        }
        if resultCode == SQLITE_INTERRUPT || databaseCode == SQLITE_INTERRUPT {
            return .creationFailed(detail + " before the preflight deadline")
        }
        return .invalidSource(message)
    }

    private static func withSQLiteProgressDeadline<T>(
        database: OpaquePointer,
        deadline: TimeInterval,
        _ body: () throws -> T
    ) throws -> T {
        var deadline = deadline
        return try withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(database, 1_000, { context in
                guard let context else { return 1 }
                let deadline = context.assumingMemoryBound(to: TimeInterval.self).pointee
                return ProcessInfo.processInfo.systemUptime < deadline ? 0 : 1
            }, pointer)
            defer { sqlite3_progress_handler(database, 0, nil, nil) }
            return try body()
        }
    }

    private static func hasRegisteredOpenDatabase(at databaseURL: URL) throws -> Bool {
        var status = stat()
        let result = databaseURL.path.withCString { Darwin.lstat($0, &status) }
        if result != 0, errno == ENOENT { return false }
        guard result == 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source identity could not be inspected"
            )
        }
        let identity = SQLiteFileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        openRegistrationLock.lock()
        defer { openRegistrationLock.unlock() }
        return (openRegistrationCounts[identity] ?? 0) > 0
    }

    private static func sqliteFileIdentity(at url: URL) throws -> SQLiteFileIdentity {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source is not an owner-controlled, singly linked regular file"
            )
        }
        return SQLiteFileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    private static func sqliteSourceState(
        databaseURL: URL,
        maximumBytes: UInt64,
        deadline: TimeInterval
    ) throws -> SQLiteSourceState {
        let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")
        var journalStatus = stat()
        let journalResult = journalURL.path.withCString { Darwin.lstat($0, &journalStatus) }
        if journalResult == 0 {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite rollback journal requires explicit recovery"
            )
        }
        guard errno == ENOENT else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite rollback-journal state could not be inspected"
            )
        }

        var remaining = maximumBytes
        let database = try sourceFileDigestIfPresent(
            at: databaseURL,
            remainingBytes: &remaining,
            deadline: deadline,
            requireStableMetadata: true
        )
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let wal = try sourceFileDigestIfPresent(
            at: walURL,
            remainingBytes: &remaining,
            deadline: deadline,
            requireStableMetadata: true
        )
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        let shm = try sourceFileDigestIfPresent(
            at: shmURL,
            remainingBytes: &remaining,
            deadline: deadline,
            requireStableMetadata: false
        )
        guard database != nil || (wal == nil && shm == nil) else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source has orphaned sidecars"
            )
        }
        guard wal != nil || shm == nil else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source has shared memory without a write-ahead log"
            )
        }
        return SQLiteSourceState(
            database: database,
            writeAheadLog: wal,
            sharedMemory: shm
        )
    }

    private static func sourceFileDigestIfPresent(
        at url: URL,
        remainingBytes: inout UInt64,
        deadline: TimeInterval,
        requireStableMetadata: Bool
    ) throws -> SQLiteSourceFileDigest? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source family member could not be opened without following links"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_uid == Darwin.geteuid(),
              initial.st_nlink == 1,
              initial.st_size >= 0,
              UInt64(initial.st_size) <= remainingBytes else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source family exceeds its byte limit or is not owner-controlled"
            )
        }
        remainingBytes -= UInt64(initial.st_size)
        var digest = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while consumed < initial.st_size {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "SQLite source hashing exceeded its deadline"
                )
            }
            let requested = min(buffer.count, Int(initial.st_size - consumed))
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "SQLite source changed while it was hashed"
                )
            }
            digest.update(data: Data(buffer[0..<count]))
            consumed += Int64(count)
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              (!requireStableMetadata || (
                final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec
                    && final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec
              )) else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite source changed while it was hashed"
            )
        }
        return SQLiteSourceFileDigest(
            identity: SQLiteFileIdentity(
                device: UInt64(initial.st_dev),
                inode: UInt64(initial.st_ino)
            ),
            bytes: UInt64(initial.st_size),
            modifiedSeconds: Int64(initial.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(initial.st_mtimespec.tv_nsec),
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func streamCopyForPreflight(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: UInt64,
        deadline: TimeInterval
    ) throws -> SQLiteSourceFileDigest {
        var remaining = maximumBytes
        let expected = try sourceFileDigestIfPresent(
            at: sourceURL,
            remainingBytes: &remaining,
            deadline: deadline,
            requireStableMetadata: true
        )
        guard let expected else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite source disappeared while it was staged"
            )
        }
        let source = sourceURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard source >= 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite source could not be reopened for staging"
            )
        }
        defer { _ = Darwin.close(source) }
        let destination = try createOwnerOnlyFile(at: destinationURL)
        defer { _ = Darwin.close(destination) }
        var digest = SHA256()
        var copied: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while copied < expected.bytes {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "SQLite source staging exceeded its deadline"
                )
            }
            let requested = min(buffer.count, Int(expected.bytes - copied))
            let count = Darwin.read(source, &buffer, requested)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "SQLite source changed while it was staged"
                )
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw VerifiedMigrationBackupError.creationFailed(
                        "SQLite private preflight copy could not be written"
                    )
                }
                written += result
            }
            digest.update(data: Data(buffer[0..<count]))
            copied += UInt64(count)
        }
        guard Darwin.fsync(destination) == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite private preflight copy could not be synchronized"
            )
        }
        var finalSource = stat()
        guard Darwin.fstat(source, &finalSource) == 0,
              UInt64(finalSource.st_dev) == expected.identity.device,
              UInt64(finalSource.st_ino) == expected.identity.inode,
              UInt64(finalSource.st_size) == expected.bytes,
              Int64(finalSource.st_mtimespec.tv_sec) == expected.modifiedSeconds,
              Int64(finalSource.st_mtimespec.tv_nsec) == expected.modifiedNanoseconds else {
            throw VerifiedMigrationBackupError.creationFailed(
                "SQLite source changed while it was staged"
            )
        }
        return SQLiteSourceFileDigest(
            identity: expected.identity,
            bytes: expected.bytes,
            modifiedSeconds: expected.modifiedSeconds,
            modifiedNanoseconds: expected.modifiedNanoseconds,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func requireSameDirectory(_ first: URL, _ second: URL) throws {
        let firstDirectory = first.deletingLastPathComponent().standardizedFileURL.path
        let secondDirectory = second.deletingLastPathComponent().standardizedFileURL.path
        guard firstDirectory == secondDirectory,
              isSimpleFilename(first.lastPathComponent),
              isSimpleFilename(second.lastPathComponent) else {
            throw VerifiedMigrationBackupError.invalidSource(
                "migration artifacts must use simple filenames in the source directory"
            )
        }
    }

    private static func migrationIdentifier(
        sourceFilename: String,
        backupFilename: String,
        sourceVersion: Int,
        targetVersion: Int,
        storageKind: VerifiedMigrationStorageKind,
        sourceSHA256: String,
        sourceBytes: UInt64,
        targetSHA256: String?,
        targetBytes: UInt64?
    ) -> String {
        let fileTargetSHA = storageKind == .file ? targetSHA256 ?? "" : ""
        let fileTargetBytes = storageKind == .file ? String(targetBytes ?? 0) : "0"
        return JSONSupport.sha256Hex([
            "forge-migration-manifest-v1",
            storageKind.rawValue,
            sourceFilename,
            backupFilename,
            String(sourceVersion),
            String(targetVersion),
            sourceSHA256,
            String(sourceBytes),
            fileTargetSHA,
            fileTargetBytes,
        ].joined(separator: "|"))
    }

    private static func rollbackInstructions(
        sourceFilename: String,
        backupFilename: String,
        sourceVersion: Int,
        sha256: String,
        bytes: UInt64,
        storageKind: VerifiedMigrationStorageKind
    ) -> [String] {
        var instructions = [
            "Stop every Forge Conductor process that can access \(sourceFilename).",
            "Preserve the current \(sourceFilename) before restoring an earlier format.",
        ]
        if storageKind == .sqlite {
            instructions.append(
                "Move any \(sourceFilename)-wal, \(sourceFilename)-shm, and \(sourceFilename)-journal sidecars aside before restore."
            )
        }
        instructions.append(
            "Restore \(backupFilename) as \(sourceFilename) with owner-only permissions."
        )
        instructions.append(
            "Verify the restored file is \(bytes) bytes with SHA-256 \(sha256)."
        )
        instructions.append(
            "Reopen it only with a build that supports schema version \(sourceVersion)."
        )
        return instructions
    }

    private static func validateManifest(_ manifest: VerifiedMigrationBackupManifest) throws {
        guard manifest.schemaVersion == manifestSchemaVersion,
              isSHA256(manifest.migrationID),
              isSimpleFilename(manifest.sourceFilename),
              isSimpleFilename(manifest.backupFilename),
              manifest.sourceFilename != manifest.backupFilename,
              manifest.sourceVersion >= 0,
              manifest.sourceVersion > 0 || manifest.storageKind == .sqlite,
              manifest.targetVersion > manifest.sourceVersion,
              isSHA256(manifest.sourceSHA256),
              isSHA256(manifest.backupSHA256),
              manifest.sourceSHA256 == manifest.backupSHA256,
              manifest.sourceBytes > 0,
              manifest.sourceBytes <= maximumSQLiteBackupBytes,
              manifest.sourceBytes == manifest.backupBytes,
              ISO8601.date(from: manifest.preparedAt) != nil,
              !manifest.rollbackInstructions.isEmpty,
              manifest.rollbackInstructions.count <= 8,
              manifest.rollbackInstructions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }),
              manifest.rollbackInstructions.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest identity, bounds, or source metadata is invalid"
            )
        }
        let targetPairIsComplete = (manifest.targetSHA256 == nil) == (manifest.targetBytes == nil)
        guard targetPairIsComplete else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest target digest and byte count must be recorded together"
            )
        }
        if let targetSHA256 = manifest.targetSHA256,
           let targetBytes = manifest.targetBytes {
            guard isSHA256(targetSHA256),
                  targetBytes > 0,
                  targetBytes <= maximumSQLiteBackupBytes else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "migration manifest target metadata is invalid"
                )
            }
        }
        switch manifest.storageKind {
        case .file:
            guard let artifact = manifest.targetArtifactFilename,
                  isSimpleFilename(artifact),
                  artifact != manifest.sourceFilename,
                  artifact != manifest.backupFilename,
                  manifest.targetSHA256 != nil,
                  manifest.targetBytes != nil else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "file migration manifest target artifact is invalid"
                )
            }
        case .sqlite:
            guard manifest.targetArtifactFilename == nil else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "SQLite migration manifest cannot reference a file target artifact"
                )
            }
        }
        switch manifest.state {
        case .prepared:
            guard manifest.completedAt == nil else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "prepared migration manifest has a completion timestamp"
                )
            }
        case .completed:
            guard manifest.targetSHA256 != nil,
                  manifest.targetBytes != nil,
                  let completedAt = manifest.completedAt,
                  ISO8601.date(from: completedAt) != nil else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "completed migration manifest lacks verified target metadata"
                )
            }
        }
        let expectedID = migrationIdentifier(
            sourceFilename: manifest.sourceFilename,
            backupFilename: manifest.backupFilename,
            sourceVersion: manifest.sourceVersion,
            targetVersion: manifest.targetVersion,
            storageKind: manifest.storageKind,
            sourceSHA256: manifest.sourceSHA256,
            sourceBytes: manifest.sourceBytes,
            targetSHA256: manifest.targetSHA256,
            targetBytes: manifest.targetBytes
        )
        guard manifest.migrationID == expectedID else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest identifier does not match its immutable fields"
            )
        }
    }

    private static func validateManifestArtifacts(
        _ manifest: VerifiedMigrationBackupManifest,
        sourceURL: URL
    ) throws {
        try validateManifest(manifest)
        guard sourceURL.lastPathComponent == manifest.sourceFilename else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest belongs to a different source file"
            )
        }
        let directory = sourceURL.deletingLastPathComponent()
        let backupURL = directory.appendingPathComponent(manifest.backupFilename)
        try requireSameDirectory(sourceURL, backupURL)
        let backup = try metadata(
            for: backupURL,
            maximumBytes: manifest.backupBytes
        )
        guard backup.sha256 == manifest.backupSHA256,
              backup.bytes == manifest.backupBytes else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration backup no longer matches its manifest"
            )
        }
        if let targetArtifactFilename = manifest.targetArtifactFilename {
            let targetURL = directory.appendingPathComponent(targetArtifactFilename)
            try requireSameDirectory(sourceURL, targetURL)
            let target = try metadata(
                for: targetURL,
                maximumBytes: manifest.targetBytes ?? maximumSQLiteBackupBytes
            )
            guard target.sha256 == manifest.targetSHA256,
                  target.bytes == manifest.targetBytes else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "migration target artifact no longer matches its manifest"
                )
            }
        }
    }

    private static func completionMetadata(
        for manifest: VerifiedMigrationBackupManifest,
        sourceURL: URL,
        supplied: VerifiedMigrationBackupMetadata?
    ) throws -> VerifiedMigrationBackupMetadata {
        switch manifest.storageKind {
        case .file:
            guard let targetArtifactFilename = manifest.targetArtifactFilename else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "file migration target artifact is missing"
                )
            }
            let targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
                targetArtifactFilename
            )
            let target = try metadata(
                for: targetURL,
                maximumBytes: manifest.targetBytes ?? maximumSQLiteBackupBytes
            )
            guard target.sha256 == manifest.targetSHA256,
                  target.bytes == manifest.targetBytes else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "file migration target artifact changed before completion"
                )
            }
            if let supplied {
                guard supplied.sha256 == target.sha256,
                      supplied.bytes == target.bytes else {
                    throw VerifiedMigrationBackupError.reconciliationFailed(
                        "supplied file migration target metadata is inconsistent"
                    )
                }
            }
            let live = try metadata(
                for: sourceURL,
                maximumBytes: manifest.targetBytes ?? maximumSQLiteBackupBytes
            )
            guard live.sha256 == target.sha256, live.bytes == target.bytes else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "installed file migration target does not match its verified artifact"
                )
            }
            return target
        case .sqlite:
            guard let supplied,
                  supplied.origin == .sqliteSnapshot,
                  isSHA256(supplied.sha256),
                  supplied.bytes > 0,
                  supplied.bytes <= maximumSQLiteBackupBytes else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "SQLite migration completion requires verified logical target metadata"
                )
            }
            return supplied
        }
    }

    private static func hasSameMigrationIdentity(
        _ first: VerifiedMigrationBackupManifest,
        _ second: VerifiedMigrationBackupManifest
    ) -> Bool {
        first.migrationID == second.migrationID
            && first.schemaVersion == second.schemaVersion
            && first.storageKind == second.storageKind
            && first.sourceFilename == second.sourceFilename
            && first.sourceVersion == second.sourceVersion
            && first.sourceSHA256 == second.sourceSHA256
            && first.sourceBytes == second.sourceBytes
            && first.backupFilename == second.backupFilename
            && first.backupSHA256 == second.backupSHA256
            && first.backupBytes == second.backupBytes
            && first.targetVersion == second.targetVersion
            && first.targetArtifactFilename == second.targetArtifactFilename
            && first.rollbackInstructions == second.rollbackInstructions
    }

    private static func preparedManifest(
        from manifest: VerifiedMigrationBackupManifest,
        preparedAt: String
    ) -> VerifiedMigrationBackupManifest {
        VerifiedMigrationBackupManifest(
            schemaVersion: manifest.schemaVersion,
            migrationID: manifest.migrationID,
            state: .prepared,
            storageKind: manifest.storageKind,
            sourceFilename: manifest.sourceFilename,
            sourceVersion: manifest.sourceVersion,
            sourceSHA256: manifest.sourceSHA256,
            sourceBytes: manifest.sourceBytes,
            backupFilename: manifest.backupFilename,
            backupSHA256: manifest.backupSHA256,
            backupBytes: manifest.backupBytes,
            targetVersion: manifest.targetVersion,
            targetSHA256: manifest.storageKind == .file ? manifest.targetSHA256 : nil,
            targetBytes: manifest.storageKind == .file ? manifest.targetBytes : nil,
            targetArtifactFilename: manifest.targetArtifactFilename,
            rollbackInstructions: manifest.rollbackInstructions,
            preparedAt: preparedAt,
            completedAt: nil
        )
    }

    private static func fileMigrationLineageURL(
        preferredURL: URL,
        lineage: Int
    ) -> URL {
        guard lineage > 1 else { return preferredURL }
        let extensionName = preferredURL.pathExtension
        let stemURL = extensionName.isEmpty
            ? preferredURL
            : preferredURL.deletingPathExtension()
        let lineageURL = stemURL.deletingLastPathComponent().appendingPathComponent(
            "\(stemURL.lastPathComponent).lineage-\(lineage)",
            isDirectory: false
        )
        return extensionName.isEmpty
            ? lineageURL
            : lineageURL.appendingPathExtension(extensionName)
    }

    @discardableResult
    private static func archiveCompletedManifest(
        _ manifest: VerifiedMigrationBackupManifest,
        sourceURL: URL
    ) throws -> VerifiedMigrationBackupManifest {
        guard manifest.state == .completed else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "only completed migration manifests can be archived"
            )
        }
        try validateManifestArtifacts(manifest, sourceURL: sourceURL)
        let backupURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            manifest.backupFilename
        )
        let archiveURL = archivedManifestURL(
            for: backupURL,
            targetVersion: manifest.targetVersion
        )
        if let archived = try readManifestIfPresent(at: archiveURL) {
            try validateManifestArtifacts(archived, sourceURL: sourceURL)
            guard archived.state == .completed,
                  hasSameMigrationIdentity(archived, manifest),
                  archived.targetSHA256 == manifest.targetSHA256,
                  archived.targetBytes == manifest.targetBytes else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "archived migration manifest conflicts with the active lineage"
                )
            }
            return archived
        }
        let data = try encodedManifest(manifest)
        _ = try writeFile(data, to: archiveURL, maximumBytes: maximumManifestBytes)
        let archived = try requireManifest(at: archiveURL)
        guard archived == manifest else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "archived migration manifest differs from the completed state"
            )
        }
        return archived
    }

    private static func promoteArchivedSQLiteCompletionIfPresent(
        _ manifest: VerifiedMigrationBackupManifest,
        sourceURL: URL
    ) throws -> VerifiedMigrationBackupManifest {
        guard manifest.state == .prepared else { return manifest }
        let backupURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            manifest.backupFilename
        )
        let archiveURL = archivedManifestURL(
            for: backupURL,
            targetVersion: manifest.targetVersion
        )
        guard let archived = try readManifestIfPresent(at: archiveURL) else {
            return manifest
        }
        try validateManifestArtifacts(archived, sourceURL: sourceURL)
        guard archived.state == .completed,
              archived.storageKind == .sqlite,
              hasSameMigrationIdentity(archived, manifest),
              archived.preparedAt == manifest.preparedAt,
              archived.targetSHA256 != nil,
              archived.targetBytes != nil else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "archived SQLite completion conflicts with the prepared lineage"
            )
        }
        let activeURL = activeManifestURL(for: sourceURL)
        let active = try requireManifest(at: activeURL)
        if active == archived { return archived }
        guard active.state == .prepared,
              hasSameMigrationIdentity(active, archived),
              active.preparedAt == archived.preparedAt else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "active SQLite lineage changed before archived completion recovery"
            )
        }
        try writeManifestReplacing(archived, to: activeURL)
        let installed = try requireManifest(at: activeURL)
        guard installed == archived else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "archived SQLite completion could not be restored as the active manifest"
            )
        }
        return installed
    }

    private static func writeManifestReplacing(
        _ manifest: VerifiedMigrationBackupManifest,
        to url: URL
    ) throws {
        try validateManifest(manifest)
        _ = try readManifestIfPresent(at: url)
        let data = try encodedManifest(manifest)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = try temporarySibling(of: url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try writeOwnerOnlyFile(data, to: temporaryURL)
        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "migration manifest could not be atomically replaced: "
                    + String(cString: strerror(errno))
            )
        }
        try synchronizeDirectory(at: url.deletingLastPathComponent())
        try hardenAndVerifyPermissions(at: url)
        let installed = try boundedRegularFileData(at: url, maximumBytes: maximumManifestBytes)
        guard installed == data else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "migration manifest changed during atomic installation"
            )
        }
    }

    private static func replaceOwnerOnlyFile(
        _ data: Data,
        at url: URL,
        maximumBytes: Int
    ) throws {
        guard maximumBytes > 0, !data.isEmpty, data.count <= maximumBytes else {
            throw VerifiedMigrationBackupError.invalidSource(
                "replacement file is empty or exceeds its migration limit"
            )
        }
        _ = try boundedRegularFileData(at: url, maximumBytes: maximumBytes)
        let temporaryURL = try temporarySibling(of: url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try writeOwnerOnlyFile(data, to: temporaryURL)
        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "migration target could not be atomically installed: "
                    + String(cString: strerror(errno))
            )
        }
        try synchronizeDirectory(at: url.deletingLastPathComponent())
        try hardenAndVerifyPermissions(at: url)
        let installed = try boundedRegularFileData(at: url, maximumBytes: maximumBytes)
        guard installed == data else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "migration target changed during atomic installation"
            )
        }
    }

    private static func encodedManifest(
        _ manifest: VerifiedMigrationBackupManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw VerifiedMigrationBackupError.creationFailed(
                "migration manifest exceeds its byte limit"
            )
        }
        return data
    }

    private static func requireManifest(at url: URL) throws -> VerifiedMigrationBackupManifest {
        guard let manifest = try readManifestIfPresent(at: url) else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "required migration manifest is missing"
            )
        }
        return manifest
    }

    private static func readManifestIfPresent(
        at url: URL
    ) throws -> VerifiedMigrationBackupManifest? {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1 else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest path is not an owner-controlled regular file"
            )
        }
        let data = try boundedRegularFileData(at: url, maximumBytes: maximumManifestBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest is not a JSON object"
            )
        }
        let requiredKeys: Set<String> = [
            "schema_version", "migration_id", "state", "storage_kind",
            "source_filename", "source_version", "source_sha256", "source_bytes",
            "backup_filename", "backup_sha256", "backup_bytes", "target_version",
            "rollback_instructions", "prepared_at",
        ]
        let allowedKeys = requiredKeys.union([
            "target_sha256", "target_bytes", "target_artifact_filename", "completed_at",
        ])
        let keys = Set(object.keys)
        guard requiredKeys.isSubset(of: keys), keys.isSubset(of: allowedKeys) else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest fields are missing or unknown"
            )
        }
        let manifest: VerifiedMigrationBackupManifest
        do {
            manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self, from: data)
        } catch {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "migration manifest cannot be decoded"
            )
        }
        try validateManifest(manifest)
        try hardenAndVerifyPermissions(at: url)
        return manifest
    }

    private static func isSimpleFilename(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value != "."
            && value != ".."
            && !value.contains("/")
            && value == URL(fileURLWithPath: value).lastPathComponent
    }

    private static func observedSourceCanInstallFileTarget(
        _ state: VerifiedMigrationManifestState
    ) -> Bool {
        state == .prepared || state == .completed
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
            }
    }

    private static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "migration backup byte limit must be positive"
            )
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "file could not be opened without following links"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        let status = try validatedOwnerControlledDescriptor(
            descriptor,
            purpose: "migration backup source"
        )
        guard status.st_size > 0,
              UInt64(status.st_size) <= UInt64(maximumBytes) else {
            throw VerifiedMigrationBackupError.invalidSource(
                "file is empty or exceeds the migration backup limit"
            )
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(1024 * 1024, Int(status.st_size)))
        while data.count < Int(status.st_size) {
            let requested = min(buffer.count, Int(status.st_size) - data.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw VerifiedMigrationBackupError.invalidSource(
                    "file changed while creating the migration backup"
                )
            }
            data.append(buffer, count: count)
        }
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == status.st_dev,
              finalStatus.st_ino == status.st_ino,
              finalStatus.st_size == status.st_size,
              finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec else {
            throw VerifiedMigrationBackupError.invalidSource(
                "file changed while creating the migration backup"
            )
        }
        return data
    }

    private static func regularFileAttributes(at url: URL) throws -> [FileAttributeKey: Any] {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "path is not an owner-controlled, singly linked regular file"
            )
        }
        return [
            .type: FileAttributeType.typeRegular,
            .size: NSNumber(value: status.st_size),
            .posixPermissions: NSNumber(value: status.st_mode & mode_t(0o777)),
        ]
    }

    private static func createOwnerOnlyFile(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "owner-only recovery artifact could not be created: "
                    + String(cString: strerror(errno))
            )
        }
        do {
            try validateAndHardenOwnerOnlyDescriptor(
                descriptor,
                purpose: "recovery artifact"
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func writeOwnerOnlyFile(_ data: Data, to url: URL) throws {
        let descriptor = try createOwnerOnlyFile(at: url)
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "recovery artifact source buffer is unavailable"
                )
            }
            var writtenBytes = 0
            while writtenBytes < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenBytes),
                    bytes.count - writtenBytes
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw VerifiedMigrationBackupError.creationFailed(
                        "recovery artifact write failed: \(String(cString: strerror(errno)))"
                    )
                }
                writtenBytes += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "recovery artifact could not be synchronized"
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "recovery artifact could not be closed"
            )
        }
        descriptorIsOpen = false
        try hardenAndVerifyPermissions(at: url)
    }

    private static func validateAndHardenOwnerOnlyDescriptor(
        _ descriptor: Int32,
        purpose: String
    ) throws {
        _ = try validatedOwnerControlledDescriptor(descriptor, purpose: purpose)
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "\(purpose) permissions could not be restricted"
            )
        }
        var hardenedStatus = stat()
        guard Darwin.fstat(descriptor, &hardenedStatus) == 0,
              (hardenedStatus.st_mode & mode_t(0o777)) == mode_t(ownerOnlyPermissions) else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "\(purpose) is not owner-only"
            )
        }
    }

    private static func validatedOwnerControlledDescriptor(
        _ descriptor: Int32,
        purpose: String
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "\(purpose) is not a private owner-controlled regular file"
            )
        }
        return status
    }

    private static func install(temporaryURL: URL, backupURL: URL) throws {
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: backupURL)
        } catch {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }
        }
        try synchronizeDirectory(at: backupURL.deletingLastPathComponent())
    }

    private static func hardenAndVerifyPermissions(at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "recovery artifact could not be opened without following links"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try validateAndHardenOwnerOnlyDescriptor(descriptor, purpose: "recovery artifact")
    }

    private static func metadata(
        for url: URL,
        maximumBytes: UInt64 = maximumSQLiteBackupBytes,
        timeoutSeconds: TimeInterval = sqliteBackupDeadline,
        allowEmpty: Bool = false,
        origin: VerifiedMigrationBackupMetadata.Origin = .file,
        deadlineUptime suppliedDeadlineUptime: TimeInterval? = nil
    ) throws -> VerifiedMigrationBackupMetadata {
        guard maximumBytes > 0, timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "migration artifact byte limit and deadline must be positive"
            )
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "recovery artifact could not be opened without following links"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        let status = try validatedOwnerControlledDescriptor(
            descriptor,
            purpose: "recovery artifact"
        )
        guard (allowEmpty || status.st_size > 0),
              UInt64(status.st_size) <= maximumBytes else {
            throw VerifiedMigrationBackupError.invalidSource(
                "migration artifact is empty or exceeds its byte limit"
            )
        }
        try validateAndHardenOwnerOnlyDescriptor(
            descriptor,
            purpose: "recovery artifact"
        )
        var digest = SHA256()
        let deadline = suppliedDeadlineUptime
            ?? ProcessInfo.processInfo.systemUptime + timeoutSeconds
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw VerifiedMigrationBackupError.creationFailed(
                "migration artifact hashing exceeded its deadline"
            )
        }
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while consumed < status.st_size {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "migration artifact hashing exceeded its deadline"
                )
            }
            let requested = min(buffer.count, Int(status.st_size - consumed))
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "migration artifact changed while it was hashed"
                )
            }
            digest.update(data: Data(buffer[0..<count]))
            consumed += Int64(count)
        }
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == status.st_dev,
              finalStatus.st_ino == status.st_ino,
              finalStatus.st_size == status.st_size,
              finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "migration artifact changed while it was hashed"
            )
        }
        let sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return VerifiedMigrationBackupMetadata(
            url: url,
            sha256: sha256,
            bytes: UInt64(status.st_size),
            origin: origin
        )
    }

    private static func requireSQLiteMigrationReceipt(
        database: OpaquePointer,
        sourceURL: URL,
        manifest: VerifiedMigrationBackupManifest,
        validateArtifacts: Bool,
        reconcileArchivedCompletion: Bool
    ) throws -> VerifiedMigrationBackupManifest {
        guard manifest.storageKind == .sqlite,
              manifest.state == .prepared || manifest.state == .completed else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite migration receipt belongs to an invalid manifest"
            )
        }
        if validateArtifacts {
            try validateManifestArtifacts(manifest, sourceURL: sourceURL)
        } else {
            try validateManifest(manifest)
        }
        var statement: OpaquePointer?
        let sql = """
        SELECT COUNT(*) FROM forge_migration_receipts
        WHERE migration_id=? AND receipt_schema_version=1
          AND source_filename=? AND backup_filename=?
          AND source_version=? AND target_version=?
          AND source_sha256=? AND source_bytes=?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite target is missing its migration receipt"
            )
        }
        defer { sqlite3_finalize(statement) }
        try bindMigrationReceipt(manifest, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int64(statement, 0) == 1 else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite target migration receipt does not match its manifest"
            )
        }
        guard reconcileArchivedCompletion else { return manifest }
        return try promoteArchivedSQLiteCompletionIfPresent(
            manifest,
            sourceURL: sourceURL
        )
    }

    private static func bindMigrationReceipt(
        _ manifest: VerifiedMigrationBackupManifest,
        to statement: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindings: [(Int32, String)] = [
            (1, manifest.migrationID),
            (2, manifest.sourceFilename),
            (3, manifest.backupFilename),
            (6, manifest.sourceSHA256),
        ]
        for (index, value) in bindings {
            guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
                throw VerifiedMigrationBackupError.reconciliationFailed(
                    "SQLite migration receipt text could not be bound"
                )
            }
        }
        guard sqlite3_bind_int64(statement, 4, Int64(manifest.sourceVersion)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, Int64(manifest.targetVersion)) == SQLITE_OK,
              manifest.sourceBytes <= UInt64(Int64.max),
              sqlite3_bind_int64(statement, 7, Int64(manifest.sourceBytes)) == SQLITE_OK else {
            throw VerifiedMigrationBackupError.reconciliationFailed(
                "SQLite migration receipt numeric value could not be bound"
            )
        }
    }

    private static func sqliteText(_ sql: String, database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact query could not be prepared: "
                    + String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private static func sqliteExecute(_ sql: String, database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw VerifiedMigrationBackupError.creationFailed(detail)
        }
    }

    private static func sqliteInt(_ sql: String, database: OpaquePointer) throws -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact version query could not be prepared: "
                    + String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func sqlitePositiveUInt64(
        _ sql: String,
        database: OpaquePointer
    ) throws -> UInt64 {
        guard let value = try sqliteInt(sql, database: database), value > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source size metadata is missing or invalid"
            )
        }
        return UInt64(value)
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "recovery directory could not be opened for synchronization"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw VerifiedMigrationBackupError.creationFailed(
                "recovery directory could not be synchronized"
            )
        }
    }

    private static func temporarySibling(of url: URL) throws -> URL {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).migration-tmp",
            isDirectory: false
        )
        var status = stat()
        let result = temporaryURL.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 {
            guard (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == Darwin.geteuid(),
                  status.st_nlink == 1 else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "stale migration temporary path is not an owner-controlled regular file"
                )
            }
            guard temporaryURL.path.withCString({ Darwin.unlink($0) }) == 0 else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "stale migration temporary file could not be removed"
                )
            }
            try synchronizeDirectory(at: temporaryURL.deletingLastPathComponent())
        } else if errno != ENOENT {
            throw VerifiedMigrationBackupError.creationFailed(
                "migration temporary path could not be inspected"
            )
        }
        return temporaryURL
    }

    private static func resetTemporaryDirectory(
        kind: String,
        key: String
    ) throws -> URL {
        let suffix = String(JSONSupport.sha256Hex(key).prefix(32))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-\(kind)-\(suffix)",
            isDirectory: true
        )
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == Darwin.geteuid() else {
                throw VerifiedMigrationBackupError.creationFailed(
                    "stale migration temporary directory is not owner-controlled"
                )
            }
            try FileManager.default.removeItem(at: url)
        } else if errno != ENOENT {
            throw VerifiedMigrationBackupError.creationFailed(
                "migration temporary directory could not be inspected"
            )
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try synchronizeDirectory(at: url.deletingLastPathComponent())
        return url
    }
}
