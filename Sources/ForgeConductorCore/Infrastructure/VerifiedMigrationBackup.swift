// VerifiedMigrationBackup.swift
// Creates bounded, owner-only recovery artifacts before durable-format migrations.

import CryptoKit
import Darwin
import Foundation
import SQLite3

public struct VerifiedMigrationBackupMetadata: Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let bytes: UInt64

    public init(url: URL, sha256: String, bytes: UInt64) {
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public enum VerifiedMigrationBackupError: Error, LocalizedError, Sendable {
    case invalidSource(String)
    case corruptSource(String)
    case creationFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let detail): "Migration backup source is invalid: \(detail)"
        case .corruptSource(let detail): "Migration backup source is corrupt: \(detail)"
        case .creationFailed(let detail): "Migration backup could not be created: \(detail)"
        case .verificationFailed(let detail): "Migration backup verification failed: \(detail)"
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
    static func withMigrationLock<T>(
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

                let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "forge-sqlite-preflight-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: stagingRoot,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
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
        let temporaryURL = temporarySibling(of: backupURL)
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
        let temporaryURL = temporarySibling(of: backupURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let source = try streamCopyForPreflight(
            from: sourceURL,
            to: temporaryURL,
            maximumBytes: maximumBytes,
            deadline: deadline
        )
        let staged = try metadata(for: temporaryURL)
        guard staged.bytes == source.bytes, staged.sha256 == source.sha256 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "staged recovery artifact differs from the stable source"
            )
        }
        try install(temporaryURL: temporaryURL, backupURL: backupURL)
        try hardenAndVerifyPermissions(at: backupURL)
        let installed = try metadata(for: backupURL)
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
        timeoutSeconds: TimeInterval = sqliteBackupDeadline
    ) throws -> VerifiedMigrationBackupMetadata {
        guard expectedVersion > 0, !versionQuery.isEmpty,
              maximumBytes > 0,
              timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw VerifiedMigrationBackupError.invalidSource(
                "SQLite source version, version query, byte limit, and deadline are required"
            )
        }
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
        let temporaryURL = temporarySibling(of: backupURL)
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

        let deadlineUptime = ProcessInfo.processInfo.systemUptime + timeoutSeconds
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
            maximumBytes: maximumBytes
        )
        try synchronizeFile(at: temporaryURL)
        try hardenAndVerifyPermissions(at: temporaryURL)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let existing = try verifySQLiteBackup(
                at: backupURL,
                expectedVersion: expectedVersion,
                versionQuery: versionQuery,
                maximumBytes: maximumBytes
            )
            guard existing.bytes == snapshot.bytes,
                  existing.sha256 == snapshot.sha256 else {
                throw VerifiedMigrationBackupError.verificationFailed(
                    "existing SQLite recovery artifact differs from the current logical source"
                )
            }
            return existing
        }
        do {
            try install(temporaryURL: temporaryURL, backupURL: backupURL)
        } catch let error as VerifiedMigrationBackupError {
            throw error
        } catch {
            throw VerifiedMigrationBackupError.creationFailed(error.localizedDescription)
        }
        let installed = try verifySQLiteBackup(
            at: backupURL,
            expectedVersion: expectedVersion,
            versionQuery: versionQuery,
            maximumBytes: maximumBytes
        )
        guard installed.bytes == snapshot.bytes,
              installed.sha256 == snapshot.sha256 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "installed SQLite recovery artifact differs from the current logical source"
            )
        }
        return installed
    }

    private static func verifySQLiteBackup(
        at url: URL,
        expectedVersion: Int,
        versionQuery: String,
        maximumBytes: UInt64
    ) throws -> VerifiedMigrationBackupMetadata {
        let attributes = try regularFileAttributes(at: url)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value > 0,
              size.uint64Value <= maximumBytes else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact is empty or exceeds its byte limit"
            )
        }
        let validationDescriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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
        var openedStatus = stat()
        let statusResult = url.path.withCString { Darwin.lstat($0, &openedStatus) }
        guard statusResult == 0,
              openedStatus.st_dev == validatedStatus.st_dev,
              openedStatus.st_ino == validatedStatus.st_ino else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "SQLite recovery artifact changed while it was opened"
            )
        }
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
        try hardenAndVerifyPermissions(at: url)
        return try metadata(for: url)
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
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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

    private static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "recovery artifact could not be opened without following links"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try validateAndHardenOwnerOnlyDescriptor(descriptor, purpose: "recovery artifact")
    }

    private static func metadata(for url: URL) throws -> VerifiedMigrationBackupMetadata {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw VerifiedMigrationBackupError.verificationFailed(
                "recovery artifact could not be opened without following links"
            )
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
        }
        let status = try validatedOwnerControlledDescriptor(
            descriptor,
            purpose: "recovery artifact"
        )
        var digest = SHA256()
        let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        descriptorIsOpen = false
        defer { try? stream.close() }
        while let block = try stream.read(upToCount: 1024 * 1024), !block.isEmpty {
            digest.update(data: block)
        }
        let sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return VerifiedMigrationBackupMetadata(
            url: url,
            sha256: sha256,
            bytes: UInt64(status.st_size)
        )
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

    private static func temporarySibling(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
    }
}
