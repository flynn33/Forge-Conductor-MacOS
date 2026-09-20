// StjornarvaldPolicySourceCatalog.swift
// What: Durably accepts every selected policy source and indexes it incrementally.
// How: SQLite owns identities/revisions/work cursors; bounded native passes inspect exact roots.
// Why: Source format, size, encryption, and filesystem kind must never gate acceptance.

import CommonCrypto
import Darwin
import Foundation
import SQLite3

public enum StjornarvaldPolicySourceError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case invalidRequest(String)
    case conflict(String)
    case sqlite(String)
    case corruptState(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Policy source catalog unavailable: \(detail)"
        case .invalidRequest(let detail): "Invalid policy source request: \(detail)"
        case .conflict(let detail): "Policy source request conflict: \(detail)"
        case .sqlite(let detail): "Policy source SQLite error: \(detail)"
        case .corruptState(let detail): "Policy source state is corrupt: \(detail)"
        }
    }
}

/// Balanced read access for a selected exact root. Bookmark resolution failure
/// falls back to the recorded path and is reported as a stale/access observation.
public final class PolicySourceAccessGrant: @unchecked Sendable {
    public let selectedURL: URL
    public let bookmarkWasStale: Bool
    public let bookmarkResolutionError: String?
    private let securityScoped: Bool

    public init(selectedPath: String, bookmarkData: Data?) {
        let fallback = URL(fileURLWithPath: selectedPath).standardizedFileURL
        guard let bookmarkData else {
            selectedURL = fallback
            bookmarkWasStale = false
            bookmarkResolutionError = nil
            securityScoped = false
            return
        }
        var stale = false
        do {
            let resolved = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            selectedURL = resolved.standardizedFileURL
            bookmarkWasStale = stale
            bookmarkResolutionError = nil
            securityScoped = resolved.startAccessingSecurityScopedResource()
        } catch {
            selectedURL = fallback
            bookmarkWasStale = false
            bookmarkResolutionError = error.localizedDescription
            securityScoped = false
        }
    }

    deinit {
        if securityScoped { selectedURL.stopAccessingSecurityScopedResource() }
    }
}

public final class StjornarvaldPolicySourceCatalog: DevelopmentPolicySourceCataloging, @unchecked Sendable {
    public static let schemaVersion = 1
    public static let maximumWorkItemsPerBatch = 256
    public static let maximumBytesPerBatch = 4 * 1_048_576
    public static let regularFileChunkBytes = 256 * 1_024
    public static let directoryEntriesPerPass = 64
    public static let maximumDirectoryEntriesScannedPerPass = 1_000_000
    public static let maximumWorkItemsPerRevision = 100_000

    private enum WorkKind: String { case inspect, enumerateDirectory = "enumerate_directory", readRegularFile = "read_regular_file" }
    private enum WorkState: String { case pending, complete, abandoned }
    private struct WorkItem {
        let id: Int64
        let revisionID: PolicySourceRevisionID
        let relativePath: String
        let kind: WorkKind
        let directoryOffset: Int64
        let byteOffset: Int64
        let hashState: Data?
        let expectedDevice: UInt64?
        let expectedInode: UInt64?
        let expectedSize: Int64?
        let expectedModifiedNanos: Int64?
    }
    private struct SourceAccessRecord {
        let source: DevelopmentPolicySource
        let bookmarkData: Data?
    }
    private struct GitIdentity {
        let repositoryURL: String?
        let commit: String?
        let branch: String?
    }
    private enum SQLiteValue { case text(String), integer(Int64), double(Double), blob(Data), null }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let lock = NSLock()
    private let diagnostics: @Sendable (String) -> Void
    private var database: OpaquePointer?
    public let databaseURL: URL
    public let sourceStoreDirectory: URL

    public init(
        databaseURL: URL,
        sourceStoreDirectory: URL,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        self.sourceStoreDirectory = sourceStoreDirectory.standardizedFileURL
        self.diagnostics = diagnostics
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.createDirectory(
                at: sourceStoreDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceStoreDirectory.path)
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

    public convenience init(
        paths: AppPaths,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        try self.init(
            databaseURL: paths.stjornarvaldPolicyLogSQLite,
            sourceStoreDirectory: paths.stjornarvaldSourceStoreDir,
            diagnostics: diagnostics
        )
    }

    deinit { if let database { sqlite3_close(database) } }

    public func add(selectedURL: URL, requestID: UUID) async throws -> DevelopmentPolicySource {
        try addSync(selectedURL: selectedURL, requestID: requestID)
    }

    public func refresh(sourceID: PolicySourceID, requestID: UUID) async throws {
        try refreshSync(sourceID: sourceID, requestID: requestID)
    }

    public func remove(sourceID: PolicySourceID, requestID: UUID) async throws {
        try removeSync(sourceID: sourceID, requestID: requestID)
    }

    public func schedule(sourceID: PolicySourceID) async {
        do { try scheduleOrThrow(sourceID: sourceID) }
        catch { diagnostics("Stjornarvald source indexing was deferred: \(error.localizedDescription)") }
    }

    public func scheduleOrThrow(sourceID: PolicySourceID) throws {
        lock.lock()
        defer { lock.unlock() }
        try scheduleUnlocked(sourceID: sourceID)
    }

    @discardableResult
    public func runNextBatch(
        sourceID: PolicySourceID,
        maximumWorkItems: Int = 32,
        maximumBytes: Int = 1_048_576
    ) throws -> PolicySourceIndexProgress {
        lock.lock()
        defer { lock.unlock() }
        let workLimit = min(max(maximumWorkItems, 1), Self.maximumWorkItemsPerBatch)
        var byteBudget = min(max(maximumBytes, 1), Self.maximumBytesPerBatch)
        guard let access = try sourceAccessUnlocked(sourceID: sourceID) else {
            throw StjornarvaldPolicySourceError.invalidRequest("unknown source \(sourceID)")
        }
        guard access.source.active else { return try progressUnlocked(sourceID: sourceID) }
        if access.source.interpretationState == .accepted
            || access.source.interpretationState == .refreshPending
            || access.source.interpretationState == .sourceUnavailable {
            try scheduleUnlocked(sourceID: sourceID)
        }
        let grant = PolicySourceAccessGrant(
            selectedPath: access.source.standardizedPath,
            bookmarkData: access.bookmarkData
        )
        if grant.bookmarkWasStale || grant.bookmarkResolutionError != nil {
            let observation = grant.bookmarkWasStale
                ? "The security-scoped bookmark is stale; the recorded path remains active."
                : "Bookmark resolution failed; the recorded path remains active."
            try updateSourceObservationUnlocked(sourceID: sourceID, observation: observation)
        }
        if let revisionID = try sourceAccessUnlocked(sourceID: sourceID)?.source.latestRevisionID {
            try captureGitIdentityUnlocked(revisionID: revisionID, root: grant.selectedURL)
        }

        var processed = 0
        while processed < workLimit,
              let work = try nextWorkUnlocked(sourceID: sourceID) {
            switch work.kind {
            case .inspect:
                try inspectUnlocked(work, root: grant.selectedURL)
            case .enumerateDirectory:
                try enumerateDirectoryUnlocked(work, root: grant.selectedURL)
            case .readRegularFile:
                let consumed = try readRegularFileUnlocked(
                    work, root: grant.selectedURL,
                    maximumBytes: min(byteBudget, Self.regularFileChunkBytes)
                )
                byteBudget = max(0, byteBudget - consumed)
            }
            processed += 1
            if byteBudget == 0 { break }
        }
        try finalizeIfCompleteUnlocked(sourceID: sourceID)
        return try progressUnlocked(sourceID: sourceID)
    }

    public func sources(includeRemoved: Bool = true) throws -> [DevelopmentPolicySource] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT source_id,origin,display_name,selected_path,standardized_path,root_kind," +
            "bookmark_sha256,active,interpretation_state,added_at,latest_revision_id," +
            "last_index_cursor,last_observation FROM stj_policy_sources " +
            (includeRemoved ? "" : "WHERE active=1 ") + "ORDER BY added_at,source_id;"
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        var result: [DevelopmentPolicySource] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            result.append(try decodeSource(statement))
        }
        return result
    }

    public func revisions(sourceID: PolicySourceID, limit: Int = 100) throws -> [PolicySourceRevision] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT revision_id,source_id,observed_at,prior_revision_id,repository_url," +
            "git_commit,git_branch,git_dirty,manifest_sha256,metadata_json " +
            "FROM stj_source_revisions WHERE source_id=? ORDER BY observed_at DESC LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(sourceID.description), .integer(Int64(min(max(limit, 1), 1_000)))], to: statement)
        var result: [PolicySourceRevision] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            guard let revisionUUID = UUID(uuidString: text(statement, 0)),
                  let sourceUUID = UUID(uuidString: text(statement, 1)),
                  let observed = ISO8601.date(from: text(statement, 2)) else {
                throw StjornarvaldPolicySourceError.corruptState("malformed source revision")
            }
            let prior = optionalText(statement, 3).flatMap(UUID.init(uuidString:)).map(PolicySourceRevisionID.init)
            let dirty: Bool? = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : sqlite3_column_int(statement, 7) == 1
            result.append(PolicySourceRevision(
                id: PolicySourceRevisionID(revisionUUID), sourceID: PolicySourceID(sourceUUID),
                observedAt: observed, priorRevisionID: prior,
                repositoryURL: optionalText(statement, 4), gitCommit: optionalText(statement, 5),
                gitBranch: optionalText(statement, 6), gitDirty: dirty,
                manifestSHA256: optionalText(statement, 8),
                metadata: try decodeStringMap(text(statement, 9))
            ))
        }
        return result
    }

    public func artifacts(revisionID: PolicySourceRevisionID, limit: Int = 1_000) throws -> [PolicyArtifact] {
        lock.lock()
        defer { lock.unlock() }
        return try artifactsUnlocked(revisionID: revisionID, limit: limit)
    }

    public func segments(artifactID: PolicyArtifactID, limit: Int = 1_000) throws -> [PolicySegment] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareUnlocked(
            "SELECT segment_id,artifact_id,ordinal,locator,extraction_method,extraction_version," +
            "content,content_sha256,confidence FROM stj_policy_segments WHERE artifact_id=? " +
            "ORDER BY ordinal LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(artifactID.description), .integer(Int64(min(max(limit, 1), 1_000)))], to: statement)
        var result: [PolicySegment] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            guard let segmentUUID = UUID(uuidString: text(statement, 0)),
                  let artifactUUID = UUID(uuidString: text(statement, 1)) else {
                throw StjornarvaldPolicySourceError.corruptState("malformed policy segment")
            }
            result.append(PolicySegment(
                id: PolicySegmentID(segmentUUID), artifactID: PolicyArtifactID(artifactUUID),
                ordinal: Int(sqlite3_column_int64(statement, 2)), locator: text(statement, 3),
                extractionMethod: text(statement, 4), extractionVersion: text(statement, 5),
                content: text(statement, 6), contentSHA256: text(statement, 7),
                confidence: sqlite3_column_double(statement, 8)
            ))
        }
        return result
    }

    public func progress(sourceID: PolicySourceID) throws -> PolicySourceIndexProgress {
        lock.lock()
        defer { lock.unlock() }
        return try progressUnlocked(sourceID: sourceID)
    }

    private func addSync(selectedURL: URL, requestID: UUID) throws -> DevelopmentPolicySource {
        lock.lock()
        defer { lock.unlock() }
        let standardized = selectedURL.standardizedFileURL
        guard !standardized.path.isEmpty, standardized.path.utf8.count <= Int(PATH_MAX) else {
            throw StjornarvaldPolicySourceError.invalidRequest("selected path is empty or too long")
        }
        let displayName = standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
        guard displayName.utf8.count <= 1_024 else {
            throw StjornarvaldPolicySourceError.invalidRequest("display name exceeds its bound")
        }
        let digest = JSONSupport.sha256Hex("add\u{0}\(standardized.path)\u{0}\(displayName)")
        if let replay = try mutationReplayUnlocked(requestID: requestID, operation: "add", digest: digest) {
            guard let source = try sourceAccessUnlocked(sourceID: replay)?.source else {
                throw StjornarvaldPolicySourceError.corruptState("source mutation lost its source")
            }
            return source
        }

        let sourceID = PolicySourceID()
        let now = Date()
        let fileInfo = Self.fileInfo(standardized)
        let rootKind = fileInfo.map { Self.rootKind(mode: $0.st_mode) } ?? .unavailable
        let bookmarkData: Data?
        if rootKind == .regularFile || rootKind == .directory {
            bookmarkData = try? standardized.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            // Bookmark creation may open FIFOs/devices or resolve links. Exact
            // path plus lstat identity is the safe durable representation here.
            bookmarkData = nil
        }
        let bookmarkSHA = bookmarkData.map(JSONSupport.sha256Hex)
        let metadata = Self.sourceMetadata(url: standardized, info: fileInfo)
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try executeUnlocked(
                "INSERT INTO stj_policy_sources(source_id,origin,display_name,selected_path," +
                "standardized_path,root_kind,bookmark_data,bookmark_sha256,active," +
                "interpretation_state,added_at,source_metadata_json) VALUES(?,?,?,?,?,?,?,?,1,?,?,?);",
                [
                    .text(sourceID.description), .text(PolicySourceOrigin.userSelected.rawValue),
                    .text(displayName), .text(selectedURL.path), .text(standardized.path),
                    .text(rootKind.rawValue), bookmarkData.map(SQLiteValue.blob) ?? .null,
                    bookmarkSHA.map(SQLiteValue.text) ?? .null,
                    .text(PolicySourceInterpretationState.accepted.rawValue),
                    .text(ISO8601.string(from: now)), .text(try encodeStringMap(metadata)),
                ]
            )
            try insertSourceEventUnlocked(
                sourceID: sourceID, revisionID: nil, type: "source_added", occurredAt: now,
                detail: ["selected_path": selectedURL.path, "root_kind": rootKind.rawValue]
            )
            try insertMutationUnlocked(
                requestID: requestID, operation: "add", sourceID: sourceID, digest: digest, occurredAt: now
            )
            try secureFilesUnlocked()
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
        guard let source = try sourceAccessUnlocked(sourceID: sourceID)?.source else {
            throw StjornarvaldPolicySourceError.corruptState("accepted source could not be read back")
        }
        return source
    }

    private func refreshSync(sourceID: PolicySourceID, requestID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let digest = JSONSupport.sha256Hex("refresh\u{0}\(sourceID.description)")
        if try mutationReplayUnlocked(requestID: requestID, operation: "refresh", digest: digest) != nil { return }
        guard let source = try sourceAccessUnlocked(sourceID: sourceID)?.source else {
            throw StjornarvaldPolicySourceError.invalidRequest("unknown source \(sourceID)")
        }
        guard source.active else { throw StjornarvaldPolicySourceError.invalidRequest("removed source cannot be refreshed") }
        let now = Date()
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try executeUnlocked(
                "UPDATE stj_policy_sources SET interpretation_state=?,last_observation=? WHERE source_id=?;",
                [.text(PolicySourceInterpretationState.refreshPending.rawValue),
                 .text("Refresh accepted and awaiting bounded indexing."), .text(sourceID.description)]
            )
            try executeUnlocked(
                "UPDATE stj_source_index_work SET state=? WHERE revision_id IN " +
                "(SELECT revision_id FROM stj_source_revisions WHERE source_id=?) AND state=?;",
                [.text(WorkState.abandoned.rawValue), .text(sourceID.description), .text(WorkState.pending.rawValue)]
            )
            try insertSourceEventUnlocked(sourceID: sourceID, revisionID: nil, type: "source_refresh_requested",
                                          occurredAt: now, detail: [:])
            try insertMutationUnlocked(requestID: requestID, operation: "refresh", sourceID: sourceID,
                                       digest: digest, occurredAt: now)
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
        try scheduleUnlocked(sourceID: sourceID)
    }

    private func removeSync(sourceID: PolicySourceID, requestID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let digest = JSONSupport.sha256Hex("remove\u{0}\(sourceID.description)")
        if try mutationReplayUnlocked(requestID: requestID, operation: "remove", digest: digest) != nil { return }
        guard try sourceAccessUnlocked(sourceID: sourceID) != nil else {
            throw StjornarvaldPolicySourceError.invalidRequest("unknown source \(sourceID)")
        }
        let now = Date()
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try executeUnlocked(
                "UPDATE stj_policy_sources SET active=0,interpretation_state=?,removed_at=?," +
                "last_observation=? WHERE source_id=?;",
                [.text(PolicySourceInterpretationState.removedByUser.rawValue),
                 .text(ISO8601.string(from: now)), .text("Removed from future policy context."),
                 .text(sourceID.description)]
            )
            try executeUnlocked(
                "UPDATE stj_source_index_work SET state=? WHERE revision_id IN " +
                "(SELECT revision_id FROM stj_source_revisions WHERE source_id=?) AND state=?;",
                [.text(WorkState.abandoned.rawValue), .text(sourceID.description), .text(WorkState.pending.rawValue)]
            )
            try insertSourceEventUnlocked(sourceID: sourceID, revisionID: nil, type: "source_removed",
                                          occurredAt: now, detail: [:])
            try insertMutationUnlocked(requestID: requestID, operation: "remove", sourceID: sourceID,
                                       digest: digest, occurredAt: now)
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func scheduleUnlocked(sourceID: PolicySourceID) throws {
        guard let source = try sourceAccessUnlocked(sourceID: sourceID)?.source else {
            throw StjornarvaldPolicySourceError.invalidRequest("unknown source \(sourceID)")
        }
        guard source.active else { return }
        let pending = try scalarIntUnlocked(
            "SELECT COUNT(*) FROM stj_source_index_work WHERE state='pending' AND revision_id IN " +
            "(SELECT revision_id FROM stj_source_revisions WHERE source_id='\(sourceID.description)');"
        )
        if pending > 0 { return }
        guard source.latestRevisionID == nil
                || source.interpretationState == .accepted
                || source.interpretationState == .refreshPending
                || source.interpretationState == .sourceUnavailable else { return }

        let revisionID = PolicySourceRevisionID()
        let now = Date()
        let metadata = ["selected_root": source.standardizedPath, "root_kind": source.rootKind.rawValue]
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try executeUnlocked(
                "INSERT INTO stj_source_revisions(revision_id,source_id,observed_at,prior_revision_id," +
                "metadata_json) VALUES(?,?,?,?,?);",
                [.text(revisionID.description), .text(sourceID.description),
                 .text(ISO8601.string(from: now)),
                 source.latestRevisionID.map { .text($0.description) } ?? .null,
                 .text(try encodeStringMap(metadata))]
            )
            try enqueueWorkUnlocked(revisionID: revisionID, relativePath: ".", kind: .inspect)
            try executeUnlocked(
                "UPDATE stj_policy_sources SET latest_revision_id=?,interpretation_state=?," +
                "last_index_cursor=?,last_observation=? WHERE source_id=?;",
                [.text(revisionID.description), .text(PolicySourceInterpretationState.cataloging.rawValue),
                 .text("."), .text("Bounded indexing scheduled."), .text(sourceID.description)]
            )
            try insertSourceEventUnlocked(sourceID: sourceID, revisionID: revisionID,
                                          type: "source_revision_started", occurredAt: now, detail: metadata)
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func inspectUnlocked(_ work: WorkItem, root: URL) throws {
        let url = Self.url(root: root, relativePath: work.relativePath)
        if work.relativePath == ".git" || work.relativePath.hasPrefix(".git/")
            || work.relativePath.contains("/.git/") {
            try upsertArtifactUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: .directory, byteCount: nil, digest: nil,
                metadata: ["path": url.path, "vcs_internal": "true"],
                state: .metadataOnly, cursor: nil,
                observation: "Git internals were retained as repository metadata and not traversed as policy content."
            )
            try completeWorkUnlocked(work.id)
            return
        }
        if managerStateContains(url) {
            try upsertArtifactUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: .unknown, byteCount: nil, digest: nil,
                metadata: ["path": url.path, "manager_owned": "true"],
                state: .metadataOnly, cursor: nil,
                observation: "Manager-owned policy state was not recursively interpreted as source material."
            )
            try completeWorkUnlocked(work.id)
            return
        }
        guard let info = Self.fileInfo(url) else {
            try upsertArtifactUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: .unavailable, byteCount: nil, digest: nil,
                metadata: ["path": url.path], state: .sourceUnavailable,
                cursor: nil, observation: "The selected entry was unavailable during indexing."
            )
            try completeWorkUnlocked(work.id)
            return
        }
        let kind = StjornarvaldNativePolicyExtractor.classify(url: url, mode: info.st_mode)
        var metadata = Self.fileMetadata(url: url, info: info)
        if kind == .symbolicLink {
            metadata["link_target"] = Self.readLink(url) ?? "unavailable"
            try upsertArtifactUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: kind, byteCount: Int64(info.st_size), digest: nil,
                metadata: metadata, state: .metadataOnly, cursor: nil,
                observation: "Symbolic link identity was retained without traversal."
            )
            try completeWorkUnlocked(work.id)
            return
        }
        if kind == .directory || kind == .bundle || kind == .package {
            try upsertArtifactUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: kind, byteCount: nil, digest: nil, metadata: metadata,
                state: .indexed, cursor: nil, observation: nil
            )
            let enqueued = try enqueueWorkUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: .enumerateDirectory, expected: info
            )
            if !enqueued {
                try deferArtifactUnlocked(
                    revisionID: work.revisionID, relativePath: work.relativePath,
                    observation: "The bounded revision work queue is full; directory interpretation is deferred."
                )
            }
            try completeWorkUnlocked(work.id)
            return
        }
        if (info.st_mode & S_IFMT) == S_IFREG {
            try upsertArtifactUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: kind, byteCount: Int64(info.st_size), digest: nil,
                metadata: metadata, state: .cataloging, cursor: "0", observation: nil
            )
            let enqueued = try enqueueWorkUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                kind: .readRegularFile, expected: info,
                byteOffset: 0, hashState: Self.initialHashState()
            )
            if !enqueued {
                try deferArtifactUnlocked(
                    revisionID: work.revisionID, relativePath: work.relativePath,
                    observation: "The bounded revision work queue is full; file interpretation is deferred."
                )
            }
            try completeWorkUnlocked(work.id)
            return
        }
        try upsertArtifactUnlocked(
            revisionID: work.revisionID, relativePath: work.relativePath,
            kind: kind, byteCount: nil, digest: nil, metadata: metadata,
            state: .metadataOnly, cursor: nil,
            observation: "Special filesystem entry retained as metadata without opening its stream."
        )
        try completeWorkUnlocked(work.id)
    }

    private func enumerateDirectoryUnlocked(_ work: WorkItem, root: URL) throws {
        let url = Self.url(root: root, relativePath: work.relativePath)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            try sourceChangedOrUnavailableUnlocked(work, observation: "Directory became unavailable during traversal.")
            return
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              Self.matchesExpected(info, work: work) else {
            try sourceChangedOrUnavailableUnlocked(work, observation: "Directory changed during resumable traversal.")
            return
        }
        guard let directory = fdopendir(Darwin.dup(descriptor)) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(directory) }
        var names: [String] = []
        var scanned = 0
        var reachedEnd = false
        errno = 0
        while names.count < Self.directoryEntriesPerPass,
              scanned < Self.maximumDirectoryEntriesScannedPerPass {
            guard let entry = readdir(directory) else {
                reachedEnd = true
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            scanned += 1
            let relative = work.relativePath == "." ? name : work.relativePath + "/" + name
            if try workExistsUnlocked(
                revisionID: work.revisionID, relativePath: relative, kind: .inspect
            ) { continue }
            names.append(name)
        }
        if reachedEnd, errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var queueBoundReached = false
        for name in names.sorted() {
            let relative = work.relativePath == "." ? name : work.relativePath + "/" + name
            if try !enqueueWorkUnlocked(
                revisionID: work.revisionID, relativePath: relative, kind: .inspect
            ) {
                queueBoundReached = true
                break
            }
        }
        if queueBoundReached
            || (scanned == Self.maximumDirectoryEntriesScannedPerPass && names.isEmpty) {
            try deferArtifactUnlocked(
                revisionID: work.revisionID, relativePath: work.relativePath,
                observation: queueBoundReached
                    ? "The bounded revision work queue is full; remaining directory entries are deferred."
                    : "The bounded directory scan pass reached its hard entry ceiling; remaining entries are deferred."
            )
            try completeWorkUnlocked(work.id)
        } else if reachedEnd {
            try completeWorkUnlocked(work.id)
        } else {
            let discovered = work.directoryOffset + Int64(names.count)
            try executeUnlocked(
                "UPDATE stj_source_index_work SET directory_offset=?,updated_at=? WHERE work_id=?;",
                [.integer(discovered), .text(ISO8601.string(from: Date())), .integer(work.id)]
            )
        }
    }

    private func readRegularFileUnlocked(
        _ work: WorkItem,
        root: URL,
        maximumBytes: Int
    ) throws -> Int {
        let url = Self.url(root: root, relativePath: work.relativePath)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            try sourceChangedOrUnavailableUnlocked(work, observation: "Regular file became unavailable during bounded reading.")
            return 0
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              Self.matchesExpected(info, work: work) else {
            try sourceChangedOrUnavailableUnlocked(work, observation: "Regular file changed during bounded reading.")
            return 0
        }
        guard let hashState = work.hashState else {
            throw StjornarvaldPolicySourceError.corruptState("regular-file work lost its hash cursor")
        }
        let remaining = max(0, Int64(info.st_size) - work.byteOffset)
        let requested = min(Int64(max(maximumBytes, 1)), remaining)
        var bytes = [UInt8](repeating: 0, count: Int(requested))
        let readCount: Int
        if requested == 0 {
            readCount = 0
        } else {
            let result = Darwin.pread(descriptor, &bytes, Int(requested), off_t(work.byteOffset))
            guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            readCount = result
        }
        let chunk = Data(bytes.prefix(readCount))
        let updatedState = try Self.updateHashState(hashState, with: chunk)
        let nextOffset = work.byteOffset + Int64(readCount)
        guard readCount > 0 || nextOffset == Int64(info.st_size) else {
            try sourceChangedOrUnavailableUnlocked(work, observation: "Regular file ended before its recorded size.")
            return 0
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0, Self.matchesExpected(after, work: work) else {
            try sourceChangedOrUnavailableUnlocked(work, observation: "Regular file changed during bounded reading.")
            return readCount
        }
        if nextOffset < Int64(info.st_size) {
            try executeUnlocked(
                "UPDATE stj_source_index_work SET byte_offset=?,hash_state=?,updated_at=? WHERE work_id=?;",
                [.integer(nextOffset), .blob(updatedState), .text(ISO8601.string(from: Date())), .integer(work.id)]
            )
            try updateArtifactCursorUnlocked(revisionID: work.revisionID,
                                             relativePath: work.relativePath, cursor: String(nextOffset))
            return readCount
        }

        let digest = try Self.finalizeHashState(updatedState)
        let boundedData: Data?
        if info.st_size <= StjornarvaldNativePolicyExtractor.maximumInputBytes {
            boundedData = try Self.readAll(descriptor: descriptor, size: Int(info.st_size))
        } else {
            boundedData = nil
        }
        var metadata = Self.fileMetadata(url: url, info: info)
        let result: StjornarvaldExtractionResult
        if let boundedData {
            guard JSONSupport.sha256Hex(boundedData) == digest else {
                try sourceChangedOrUnavailableUnlocked(
                    work, observation: "Regular file changed between hashing and bounded extraction."
                )
                return readCount
            }
            result = StjornarvaldNativePolicyExtractor.extract(url: url, mode: info.st_mode, data: boundedData)
            metadata.merge(result.metadata) { _, new in new }
            try persistSnapshotUnlocked(data: boundedData, digest: digest)
        } else {
            let leadingBytes = try Self.readPrefix(
                descriptor: descriptor, maximumBytes: 512, fileSize: Int64(info.st_size)
            )
            let kind = StjornarvaldNativePolicyExtractor.classify(
                url: url, mode: info.st_mode, leadingBytes: leadingBytes
            )
            result = StjornarvaldExtractionResult(
                kind: kind, state: .partiallyIndexed, metadata: [:], segments: [],
                observation: "Content was hashed in bounded resumable passes; direct extraction is deferred by the per-artifact byte budget."
            )
        }
        let artifactID = Self.artifactID(revisionID: work.revisionID, relativePath: work.relativePath)
        try executeUnlocked("DELETE FROM stj_policy_segments WHERE artifact_id=?;", [.text(artifactID.description)])
        for (index, segment) in result.segments.enumerated() {
            try insertSegmentUnlocked(segment, artifactID: artifactID, ordinal: index)
        }
        try upsertArtifactUnlocked(
            revisionID: work.revisionID, relativePath: work.relativePath,
            kind: result.kind, byteCount: Int64(info.st_size), digest: digest,
            metadata: metadata, state: result.state, cursor: String(nextOffset),
            observation: result.observation
        )
        try completeWorkUnlocked(work.id)
        return readCount
    }

    private func sourceChangedOrUnavailableUnlocked(_ work: WorkItem, observation: String) throws {
        try executeUnlocked(
            "UPDATE stj_policy_artifacts SET interpretation_state=?,last_cursor=? " +
            "WHERE revision_id=? AND relative_path=?;",
            [.text(PolicyArtifactInterpretationState.sourceChanged.rawValue), .text(observation),
             .text(work.revisionID.description), .text(work.relativePath)]
        )
        guard let sourceID = try sourceIDUnlocked(revisionID: work.revisionID) else {
            throw StjornarvaldPolicySourceError.corruptState("work revision lost its source")
        }
        try executeUnlocked(
            "UPDATE stj_policy_sources SET interpretation_state=?,last_observation=? WHERE source_id=?;",
            [.text(PolicySourceInterpretationState.refreshPending.rawValue), .text(observation), .text(sourceID.description)]
        )
        try executeUnlocked(
            "UPDATE stj_source_index_work SET state=? WHERE revision_id=? AND state=?;",
            [.text(WorkState.abandoned.rawValue), .text(work.revisionID.description), .text(WorkState.pending.rawValue)]
        )
        try insertSourceEventUnlocked(sourceID: sourceID, revisionID: work.revisionID,
                                      type: "source_changed", occurredAt: Date(),
                                      detail: ["path": work.relativePath, "observation": observation])
    }

    private func finalizeIfCompleteUnlocked(sourceID: PolicySourceID) throws {
        guard let source = try sourceAccessUnlocked(sourceID: sourceID)?.source,
              source.active, let revisionID = source.latestRevisionID,
              source.interpretationState == .cataloging else { return }
        let pending = try countUnlocked(
            "SELECT COUNT(*) FROM stj_source_index_work WHERE revision_id=? AND state=?;",
            [.text(revisionID.description), .text(WorkState.pending.rawValue)]
        )
        guard pending == 0 else { return }
        let artifacts = try artifactsUnlocked(revisionID: revisionID, limit: 100_000)
        let manifestObject: [[String: Any]] = artifacts.map {
            ["path": $0.relativePath, "kind": $0.kind.rawValue,
             "bytes": $0.byteCount ?? -1, "digest": $0.contentSHA256 ?? "",
             "state": $0.interpretationState.rawValue]
        }
        let manifest = JSONSupport.sha256Hex(
            try JSONSupport.canonicalJSON(["artifacts": manifestObject])
        )
        let states = Set(artifacts.map(\.interpretationState))
        let sourceState: PolicySourceInterpretationState
        if states.contains(.sourceUnavailable), artifacts.count <= 1 { sourceState = .sourceUnavailable }
        else if states.isSubset(of: [.indexed]) { sourceState = .indexed }
        else { sourceState = .partiallyIndexed }
        let observation = "Indexed \(artifacts.count) artifacts with \(states.count) interpretation states."
        try execUnlocked("BEGIN IMMEDIATE;")
        do {
            try executeUnlocked(
                "UPDATE stj_source_revisions SET manifest_sha256=? WHERE revision_id=?;",
                [.text(manifest), .text(revisionID.description)]
            )
            try executeUnlocked(
                "UPDATE stj_policy_sources SET interpretation_state=?,last_index_cursor=NULL," +
                "last_observation=? WHERE source_id=?;",
                [.text(sourceState.rawValue), .text(observation), .text(sourceID.description)]
            )
            try insertSourceEventUnlocked(sourceID: sourceID, revisionID: revisionID,
                                          type: "source_index_completed", occurredAt: Date(),
                                          detail: ["manifest_sha256": manifest,
                                                   "interpretation_state": sourceState.rawValue])
            try execUnlocked("COMMIT;")
        } catch {
            try? execUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func progressUnlocked(sourceID: PolicySourceID) throws -> PolicySourceIndexProgress {
        guard let source = try sourceAccessUnlocked(sourceID: sourceID)?.source else {
            throw StjornarvaldPolicySourceError.invalidRequest("unknown source \(sourceID)")
        }
        guard let revisionID = source.latestRevisionID else {
            return PolicySourceIndexProgress(
                sourceID: sourceID, revisionID: nil, interpretationState: source.interpretationState,
                pendingWorkCount: 0, completedWorkCount: 0, artifactCount: 0, segmentCount: 0,
                cursor: source.lastIndexCursor, observation: source.latestObservation
            )
        }
        let pending = try countUnlocked(
            "SELECT COUNT(*) FROM stj_source_index_work WHERE revision_id=? AND state=?;",
            [.text(revisionID.description), .text(WorkState.pending.rawValue)]
        )
        let completed = try countUnlocked(
            "SELECT COUNT(*) FROM stj_source_index_work WHERE revision_id=? AND state=?;",
            [.text(revisionID.description), .text(WorkState.complete.rawValue)]
        )
        let artifacts = try countUnlocked(
            "SELECT COUNT(*) FROM stj_policy_artifacts WHERE revision_id=?;", [.text(revisionID.description)]
        )
        let segments = try countUnlocked(
            "SELECT COUNT(*) FROM stj_policy_segments WHERE artifact_id IN " +
            "(SELECT artifact_id FROM stj_policy_artifacts WHERE revision_id=?);",
            [.text(revisionID.description)]
        )
        return PolicySourceIndexProgress(
            sourceID: sourceID, revisionID: revisionID,
            interpretationState: source.interpretationState,
            pendingWorkCount: pending, completedWorkCount: completed,
            artifactCount: artifacts, segmentCount: segments,
            cursor: source.lastIndexCursor, observation: source.latestObservation
        )
    }

    private func artifactsUnlocked(revisionID: PolicySourceRevisionID, limit: Int) throws -> [PolicyArtifact] {
        let statement = try prepareUnlocked(
            "SELECT artifact_id,revision_id,relative_path,artifact_kind,byte_count,content_sha256," +
            "metadata_json,interpretation_state,last_cursor FROM stj_policy_artifacts " +
            "WHERE revision_id=? ORDER BY relative_path LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(revisionID.description), .integer(Int64(min(max(limit, 1), 100_000)))], to: statement)
        var result: [PolicyArtifact] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteErrorUnlocked() }
            guard let artifactUUID = UUID(uuidString: text(statement, 0)),
                  let revisionUUID = UUID(uuidString: text(statement, 1)),
                  let kind = PolicyArtifactKind(rawValue: text(statement, 3)),
                  let state = PolicyArtifactInterpretationState(rawValue: text(statement, 7)) else {
                throw StjornarvaldPolicySourceError.corruptState("malformed policy artifact")
            }
            result.append(PolicyArtifact(
                id: PolicyArtifactID(artifactUUID), revisionID: PolicySourceRevisionID(revisionUUID),
                relativePath: text(statement, 2), kind: kind,
                byteCount: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4),
                contentSHA256: optionalText(statement, 5), metadata: try decodeStringMap(text(statement, 6)),
                interpretationState: state, lastCursor: optionalText(statement, 8)
            ))
        }
        return result
    }

    private func upsertArtifactUnlocked(
        revisionID: PolicySourceRevisionID,
        relativePath: String,
        kind: PolicyArtifactKind,
        byteCount: Int64?,
        digest: String?,
        metadata: [String: String],
        state: PolicyArtifactInterpretationState,
        cursor: String?,
        observation: String?
    ) throws {
        let artifactID = Self.artifactID(revisionID: revisionID, relativePath: relativePath)
        try executeUnlocked(
            "INSERT INTO stj_policy_artifacts(artifact_id,revision_id,relative_path,artifact_kind," +
            "byte_count,content_sha256,metadata_json,interpretation_state,last_cursor) " +
            "VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(revision_id,relative_path) DO UPDATE SET " +
            "artifact_kind=excluded.artifact_kind,byte_count=excluded.byte_count," +
            "content_sha256=excluded.content_sha256,metadata_json=excluded.metadata_json," +
            "interpretation_state=excluded.interpretation_state,last_cursor=excluded.last_cursor;",
            [.text(artifactID.description), .text(revisionID.description), .text(relativePath),
             .text(kind.rawValue), byteCount.map(SQLiteValue.integer) ?? .null,
             digest.map(SQLiteValue.text) ?? .null, .text(try encodeStringMap(metadata)),
             .text(state.rawValue), cursor.map(SQLiteValue.text) ?? .null]
        )
        if let observation, let sourceID = try sourceIDUnlocked(revisionID: revisionID) {
            try updateSourceObservationUnlocked(sourceID: sourceID, observation: observation)
            try insertSourceEventUnlocked(sourceID: sourceID, revisionID: revisionID,
                                          type: "source_interpretation_observed", occurredAt: Date(),
                                          detail: ["path": relativePath, "observation": observation])
        }
    }

    private func insertSegmentUnlocked(
        _ segment: StjornarvaldExtractedSegment,
        artifactID: PolicyArtifactID,
        ordinal: Int
    ) throws {
        let segmentID = Self.segmentID(artifactID: artifactID, ordinal: ordinal)
        let boundedContent = Self.bounded(segment.content, maximumBytes: StjornarvaldNativePolicyExtractor.maximumSegmentBytes)
        try executeUnlocked(
            "INSERT INTO stj_policy_segments(segment_id,artifact_id,ordinal,locator,extraction_method," +
            "extraction_version,content,content_sha256,confidence) VALUES(?,?,?,?,?,?,?,?,?);",
            [.text(segmentID.description), .text(artifactID.description), .integer(Int64(ordinal)),
             .text(segment.locator), .text(segment.method), .text(segment.version),
             .text(boundedContent), .text(JSONSupport.sha256Hex(Data(boundedContent.utf8))),
             .double(min(max(segment.confidence, 0), 1))]
        )
    }

    @discardableResult
    private func enqueueWorkUnlocked(
        revisionID: PolicySourceRevisionID,
        relativePath: String,
        kind: WorkKind,
        expected: stat? = nil,
        byteOffset: Int64 = 0,
        hashState: Data? = nil
    ) throws -> Bool {
        guard relativePath.utf8.count <= 4_096,
              relativePath == "." || (!relativePath.hasPrefix("/")
                && !relativePath.split(separator: "/").contains("..")) else {
            throw StjornarvaldPolicySourceError.invalidRequest("relative source path is unsafe or oversized")
        }
        if try workExistsUnlocked(revisionID: revisionID, relativePath: relativePath, kind: kind) {
            return true
        }
        let count = try countUnlocked(
            "SELECT COUNT(*) FROM stj_source_index_work WHERE revision_id=?;",
            [.text(revisionID.description)]
        )
        guard count < Self.maximumWorkItemsPerRevision else { return false }
        try executeUnlocked(
            "INSERT OR IGNORE INTO stj_source_index_work(revision_id,relative_path,work_kind,state," +
            "directory_offset,byte_offset,hash_state,expected_device,expected_inode,expected_size," +
            "expected_modified_nanos,created_at,updated_at) VALUES(?,?,?,'pending',0,?,?,?,?,?,?,?,?);",
            [.text(revisionID.description), .text(relativePath), .text(kind.rawValue),
             .integer(byteOffset), hashState.map(SQLiteValue.blob) ?? .null,
             expected.map { .integer(Int64($0.st_dev)) } ?? .null,
             expected.map { .integer(Int64(bitPattern: UInt64($0.st_ino))) } ?? .null,
             expected.map { .integer(Int64($0.st_size)) } ?? .null,
             expected.map { .integer(Self.modifiedNanos($0)) } ?? .null,
             .text(ISO8601.string(from: Date())), .text(ISO8601.string(from: Date()))]
        )
        return true
    }

    private func nextWorkUnlocked(sourceID: PolicySourceID) throws -> WorkItem? {
        let statement = try prepareUnlocked(
            "SELECT w.work_id,w.revision_id,w.relative_path,w.work_kind,w.directory_offset," +
            "w.byte_offset,w.hash_state,w.expected_device,w.expected_inode,w.expected_size," +
            "w.expected_modified_nanos FROM stj_source_index_work w JOIN stj_source_revisions r " +
            "ON r.revision_id=w.revision_id JOIN stj_policy_sources s ON s.latest_revision_id=r.revision_id " +
            "WHERE s.source_id=? AND w.state=? ORDER BY w.relative_path,w.work_kind,w.work_id LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(sourceID.description), .text(WorkState.pending.rawValue)], to: statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { return nil }
            throw sqliteErrorUnlocked()
        }
        guard let revisionUUID = UUID(uuidString: text(statement, 1)),
              let kind = WorkKind(rawValue: text(statement, 3)) else {
            throw StjornarvaldPolicySourceError.corruptState("malformed source work item")
        }
        return WorkItem(
            id: sqlite3_column_int64(statement, 0), revisionID: PolicySourceRevisionID(revisionUUID),
            relativePath: text(statement, 2), kind: kind,
            directoryOffset: sqlite3_column_int64(statement, 4),
            byteOffset: sqlite3_column_int64(statement, 5), hashState: optionalBlob(statement, 6),
            expectedDevice: optionalUInt64(statement, 7), expectedInode: optionalUInt64(statement, 8),
            expectedSize: optionalInt64(statement, 9), expectedModifiedNanos: optionalInt64(statement, 10)
        )
    }

    private func workExistsUnlocked(
        revisionID: PolicySourceRevisionID,
        relativePath: String,
        kind: WorkKind
    ) throws -> Bool {
        try countUnlocked(
            "SELECT COUNT(*) FROM stj_source_index_work WHERE revision_id=? AND relative_path=? AND work_kind=?;",
            [.text(revisionID.description), .text(relativePath), .text(kind.rawValue)]
        ) > 0
    }

    private func completeWorkUnlocked(_ id: Int64) throws {
        try executeUnlocked(
            "UPDATE stj_source_index_work SET state=?,updated_at=? WHERE work_id=?;",
            [.text(WorkState.complete.rawValue), .text(ISO8601.string(from: Date())), .integer(id)]
        )
    }

    private func updateArtifactCursorUnlocked(
        revisionID: PolicySourceRevisionID,
        relativePath: String,
        cursor: String
    ) throws {
        try executeUnlocked(
            "UPDATE stj_policy_artifacts SET last_cursor=? WHERE revision_id=? AND relative_path=?;",
            [.text(cursor), .text(revisionID.description), .text(relativePath)]
        )
        if let sourceID = try sourceIDUnlocked(revisionID: revisionID) {
            try executeUnlocked(
                "UPDATE stj_policy_sources SET last_index_cursor=? WHERE source_id=?;",
                [.text(relativePath + ":" + cursor), .text(sourceID.description)]
            )
        }
    }

    private func deferArtifactUnlocked(
        revisionID: PolicySourceRevisionID,
        relativePath: String,
        observation: String
    ) throws {
        try executeUnlocked(
            "UPDATE stj_policy_artifacts SET interpretation_state=?,last_cursor=? " +
            "WHERE revision_id=? AND relative_path=?;",
            [.text(PolicyArtifactInterpretationState.extractionDeferred.rawValue),
             .text("deferred"), .text(revisionID.description), .text(relativePath)]
        )
        if let sourceID = try sourceIDUnlocked(revisionID: revisionID) {
            try updateSourceObservationUnlocked(sourceID: sourceID, observation: observation)
            try insertSourceEventUnlocked(
                sourceID: sourceID, revisionID: revisionID,
                type: "source_interpretation_deferred", occurredAt: Date(),
                detail: ["path": relativePath, "observation": observation]
            )
        }
    }

    private func updateSourceObservationUnlocked(sourceID: PolicySourceID, observation: String) throws {
        try executeUnlocked(
            "UPDATE stj_policy_sources SET last_observation=? WHERE source_id=?;",
            [.text(Self.bounded(observation, maximumBytes: 4_096)), .text(sourceID.description)]
        )
    }

    private func captureGitIdentityUnlocked(
        revisionID: PolicySourceRevisionID,
        root: URL
    ) throws {
        let statement = try prepareUnlocked(
            "SELECT metadata_json FROM stj_source_revisions WHERE revision_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(revisionID.description)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        var metadata = try decodeStringMap(text(statement, 0))
        guard metadata["git_probe_state"] == nil else { return }
        metadata["git_probe_state"] = "complete"
        metadata["git_worktree_state"] = "unassessed"
        let identity = Self.gitIdentity(for: root)
        if identity != nil { metadata["git_identity_source"] = "native-git-metadata" }
        try executeUnlocked(
            "UPDATE stj_source_revisions SET repository_url=?,git_commit=?,git_branch=?," +
            "git_dirty=NULL,metadata_json=? WHERE revision_id=?;",
            [identity?.repositoryURL.map(SQLiteValue.text) ?? .null,
             identity?.commit.map(SQLiteValue.text) ?? .null,
             identity?.branch.map(SQLiteValue.text) ?? .null,
             .text(try encodeStringMap(metadata)), .text(revisionID.description)]
        )
    }

    private func persistSnapshotUnlocked(data: Data, digest: String) throws {
        guard data.count <= StjornarvaldNativePolicyExtractor.maximumInputBytes else { return }
        let directory = sourceStoreDirectory.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent(digest)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func sourceAccessUnlocked(sourceID: PolicySourceID) throws -> SourceAccessRecord? {
        let statement = try prepareUnlocked(
            "SELECT source_id,origin,display_name,selected_path,standardized_path,root_kind," +
            "bookmark_sha256,active,interpretation_state,added_at,latest_revision_id," +
            "last_index_cursor,last_observation,bookmark_data FROM stj_policy_sources WHERE source_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(sourceID.description)], to: statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { return nil }
            throw sqliteErrorUnlocked()
        }
        return SourceAccessRecord(source: try decodeSource(statement), bookmarkData: optionalBlob(statement, 13))
    }

    private func decodeSource(_ statement: OpaquePointer) throws -> DevelopmentPolicySource {
        guard let sourceUUID = UUID(uuidString: text(statement, 0)),
              let origin = PolicySourceOrigin(rawValue: text(statement, 1)),
              let rootKind = PolicySourceRootKind(rawValue: text(statement, 5)),
              let state = PolicySourceInterpretationState(rawValue: text(statement, 8)),
              let addedAt = ISO8601.date(from: text(statement, 9)) else {
            throw StjornarvaldPolicySourceError.corruptState("malformed policy source")
        }
        let revision = optionalText(statement, 10).flatMap(UUID.init(uuidString:)).map(PolicySourceRevisionID.init)
        return DevelopmentPolicySource(
            id: PolicySourceID(sourceUUID), origin: origin, displayName: text(statement, 2),
            selectedPath: text(statement, 3), standardizedPath: text(statement, 4),
            rootKind: rootKind, bookmarkSHA256: optionalText(statement, 6),
            active: sqlite3_column_int(statement, 7) == 1, interpretationState: state,
            addedAt: addedAt, latestRevisionID: revision,
            lastIndexCursor: optionalText(statement, 11), latestObservation: optionalText(statement, 12)
        )
    }

    private func sourceIDUnlocked(revisionID: PolicySourceRevisionID) throws -> PolicySourceID? {
        let statement = try prepareUnlocked("SELECT source_id FROM stj_source_revisions WHERE revision_id=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind([.text(revisionID.description)], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let uuid = UUID(uuidString: text(statement, 0)) else {
            throw StjornarvaldPolicySourceError.corruptState("revision source identity is malformed")
        }
        return PolicySourceID(uuid)
    }

    private func mutationReplayUnlocked(
        requestID: UUID,
        operation: String,
        digest: String
    ) throws -> PolicySourceID? {
        let statement = try prepareUnlocked(
            "SELECT operation,source_id,request_sha256 FROM stj_source_mutations WHERE request_id=? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(requestID.uuidString.lowercased())], to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, text(statement, 0) == operation, text(statement, 2) == digest,
              let uuid = UUID(uuidString: text(statement, 1)) else {
            throw StjornarvaldPolicySourceError.conflict(
                "request ID \(requestID.uuidString.lowercased()) was already used for different content"
            )
        }
        return PolicySourceID(uuid)
    }

    private func insertMutationUnlocked(
        requestID: UUID,
        operation: String,
        sourceID: PolicySourceID,
        digest: String,
        occurredAt: Date
    ) throws {
        try executeUnlocked(
            "INSERT INTO stj_source_mutations(request_id,operation,source_id,request_sha256,occurred_at) " +
            "VALUES(?,?,?,?,?);",
            [.text(requestID.uuidString.lowercased()), .text(operation), .text(sourceID.description),
             .text(digest), .text(ISO8601.string(from: occurredAt))]
        )
    }

    private func insertSourceEventUnlocked(
        sourceID: PolicySourceID,
        revisionID: PolicySourceRevisionID?,
        type: String,
        occurredAt: Date,
        detail: [String: String]
    ) throws {
        try executeUnlocked(
            "INSERT INTO stj_source_events(event_id,source_id,revision_id,event_type,occurred_at,detail_json) " +
            "VALUES(?,?,?,?,?,?);",
            [.text(UUID().uuidString.lowercased()), .text(sourceID.description),
             revisionID.map { .text($0.description) } ?? .null, .text(type),
             .text(ISO8601.string(from: occurredAt)), .text(try encodeStringMap(detail))]
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
                CREATE TABLE IF NOT EXISTS stj_policy_sources (
                  source_id TEXT PRIMARY KEY, origin TEXT NOT NULL, display_name TEXT NOT NULL,
                  selected_path TEXT NOT NULL, standardized_path TEXT NOT NULL, root_kind TEXT NOT NULL,
                  bookmark_data BLOB, bookmark_sha256 TEXT, active INTEGER NOT NULL CHECK(active IN(0,1)),
                  interpretation_state TEXT NOT NULL, added_at TEXT NOT NULL, removed_at TEXT,
                  latest_revision_id TEXT, last_index_cursor TEXT, last_observation TEXT,
                  source_metadata_json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS stj_source_revisions (
                  revision_id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES stj_policy_sources(source_id),
                  observed_at TEXT NOT NULL, prior_revision_id TEXT REFERENCES stj_source_revisions(revision_id),
                  repository_url TEXT, git_commit TEXT, git_branch TEXT, git_dirty INTEGER CHECK(git_dirty IN(0,1)),
                  manifest_sha256 TEXT, metadata_json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS stj_source_revisions_source
                  ON stj_source_revisions(source_id,observed_at);
                CREATE TABLE IF NOT EXISTS stj_policy_artifacts (
                  artifact_id TEXT PRIMARY KEY, revision_id TEXT NOT NULL REFERENCES stj_source_revisions(revision_id),
                  relative_path TEXT NOT NULL, artifact_kind TEXT NOT NULL, byte_count INTEGER,
                  content_sha256 TEXT, metadata_json TEXT NOT NULL, interpretation_state TEXT NOT NULL,
                  last_cursor TEXT, UNIQUE(revision_id,relative_path)
                );
                CREATE TABLE IF NOT EXISTS stj_policy_segments (
                  segment_id TEXT PRIMARY KEY, artifact_id TEXT NOT NULL REFERENCES stj_policy_artifacts(artifact_id),
                  ordinal INTEGER NOT NULL, locator TEXT NOT NULL, extraction_method TEXT NOT NULL,
                  extraction_version TEXT NOT NULL, content TEXT NOT NULL, content_sha256 TEXT NOT NULL,
                  confidence REAL NOT NULL CHECK(confidence>=0 AND confidence<=1), UNIQUE(artifact_id,ordinal)
                );
                CREATE TABLE IF NOT EXISTS stj_source_mutations (
                  request_id TEXT PRIMARY KEY, operation TEXT NOT NULL, source_id TEXT NOT NULL,
                  request_sha256 TEXT NOT NULL, occurred_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS stj_source_events (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
                  source_id TEXT NOT NULL, revision_id TEXT, event_type TEXT NOT NULL,
                  occurred_at TEXT NOT NULL, detail_json TEXT NOT NULL
                );
                CREATE TRIGGER IF NOT EXISTS stj_source_events_no_update
                  BEFORE UPDATE ON stj_source_events
                  BEGIN SELECT RAISE(ABORT, 'policy source events are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS stj_source_events_no_delete
                  BEFORE DELETE ON stj_source_events
                  BEGIN SELECT RAISE(ABORT, 'policy source events are append-only'); END;
                CREATE TABLE IF NOT EXISTS stj_source_index_work (
                  work_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  revision_id TEXT NOT NULL REFERENCES stj_source_revisions(revision_id),
                  relative_path TEXT NOT NULL, work_kind TEXT NOT NULL, state TEXT NOT NULL,
                  directory_offset INTEGER NOT NULL DEFAULT 0, byte_offset INTEGER NOT NULL DEFAULT 0,
                  hash_state BLOB, expected_device INTEGER, expected_inode INTEGER, expected_size INTEGER,
                  expected_modified_nanos INTEGER, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                  UNIQUE(revision_id,relative_path,work_kind)
                );
                CREATE INDEX IF NOT EXISTS stj_source_index_work_pending
                  ON stj_source_index_work(revision_id,state,relative_path,work_kind);
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
        let manager = FileManager.default
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"),
                    URL(fileURLWithPath: databaseURL.path + "-shm")]
            where manager.fileExists(atPath: url.path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func managerStateContains(_ candidate: URL) -> Bool {
        let root = databaseURL.deletingLastPathComponent().standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
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

    private func countUnlocked(_ sql: String, _ values: [SQLiteValue]) throws -> Int {
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteErrorUnlocked() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarIntUnlocked(_ sql: String) throws -> Int {
        try countUnlocked(sql, [])
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
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            case .blob(let value):
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.sqliteTransient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
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

    private func optionalBlob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func optionalInt64(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    private func optionalUInt64(_ statement: OpaquePointer, _ column: Int32) -> UInt64? {
        optionalInt64(statement, column).map(UInt64.init(bitPattern:))
    }

    private static func fileInfo(_ url: URL) -> stat? {
        var value = stat()
        return Darwin.lstat(url.path, &value) == 0 ? value : nil
    }

    private static func rootKind(mode: mode_t) -> PolicySourceRootKind {
        switch mode & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        case S_IFSOCK: .socket
        case S_IFIFO: .fifo
        case S_IFCHR: .characterDevice
        case S_IFBLK: .blockDevice
        default: .unknown
        }
    }

    private static func sourceMetadata(url: URL, info: stat?) -> [String: String] {
        guard let info else { return ["path": url.path, "availability": "unavailable"] }
        return fileMetadata(url: url, info: info)
    }

    private static func fileMetadata(url: URL, info: stat) -> [String: String] {
        var values: [String: String] = [
            "path": url.path, "device": String(info.st_dev),
            "inode": String(UInt64(info.st_ino)), "mode": String(info.st_mode),
            "modified_nanos": String(modifiedNanos(info)),
        ]
        if (info.st_mode & S_IFMT) == S_IFREG { values["byte_count"] = String(info.st_size) }
        if !url.pathExtension.isEmpty { values["extension"] = url.pathExtension.lowercased() }
        return values
    }

    private static func modifiedNanos(_ info: stat) -> Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    private static func matchesExpected(_ info: stat, work: WorkItem) -> Bool {
        work.expectedDevice == UInt64(bitPattern: Int64(info.st_dev))
            && work.expectedInode == UInt64(info.st_ino)
            && work.expectedSize == Int64(info.st_size)
            && work.expectedModifiedNanos == modifiedNanos(info)
    }

    private static func url(root: URL, relativePath: String) -> URL {
        relativePath == "." ? root : root.appendingPathComponent(relativePath).standardizedFileURL
    }

    private static func readLink(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = Darwin.readlink(url.path, &buffer, Int(PATH_MAX))
        guard count >= 0 else { return nil }
        buffer[Int(count)] = 0
        return String(cString: buffer)
    }

    private static func gitIdentity(for selectedRoot: URL) -> GitIdentity? {
        let selectedInfo = fileInfo(selectedRoot)
        var directory = selectedInfo.map { ($0.st_mode & S_IFMT) == S_IFDIR } == true
            ? selectedRoot : selectedRoot.deletingLastPathComponent()
        var gitDirectory: URL?
        while directory.path != "/" {
            let marker = directory.appendingPathComponent(".git")
            if let info = fileInfo(marker) {
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    gitDirectory = marker
                    break
                }
                if (info.st_mode & S_IFMT) == S_IFREG,
                   let data = boundedFileData(marker, maximumBytes: 4_096),
                   let value = String(data: data, encoding: .utf8),
                   value.hasPrefix("gitdir:") {
                    let path = value.dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDirectory = URL(fileURLWithPath: path, relativeTo: directory)
                        .standardizedFileURL
                    break
                }
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        guard let gitDirectory,
              let headData = boundedFileData(gitDirectory.appendingPathComponent("HEAD"), maximumBytes: 4_096),
              let head = String(data: headData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty else { return nil }
        var branch: String?
        var commit: String?
        if head.hasPrefix("ref: ") {
            let reference = String(head.dropFirst(5))
            if reference.hasPrefix("refs/heads/") { branch = String(reference.dropFirst("refs/heads/".count)) }
            if !reference.hasPrefix("/") && !reference.split(separator: "/").contains("..") {
                let referenceURL = gitDirectory.appendingPathComponent(reference)
                commit = boundedFileData(referenceURL, maximumBytes: 256)
                    .flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if commit == nil,
                   let packed = boundedFileData(
                       gitDirectory.appendingPathComponent("packed-refs"), maximumBytes: 8 * 1_048_576
                   ).flatMap({ String(data: $0, encoding: .utf8) }) {
                    commit = packed.split(separator: "\n").first { line in
                        !line.hasPrefix("#") && !line.hasPrefix("^")
                            && line.hasSuffix(" " + reference)
                    }.map { String($0.split(separator: " ", maxSplits: 1)[0]) }
                }
            }
        } else {
            commit = head
        }
        if let value = commit {
            let validLength = value.count == 40 || value.count == 64
            if !validLength || !value.allSatisfy({ $0.isHexDigit }) { commit = nil }
        }
        var repositoryURL: String?
        if let config = boundedFileData(gitDirectory.appendingPathComponent("config"), maximumBytes: 1_048_576)
            .flatMap({ String(data: $0, encoding: .utf8) }) {
            var inOrigin = false
            for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]" }
                else if inOrigin, line.hasPrefix("url"), let equals = line.firstIndex(of: "=") {
                    repositoryURL = redactURLCredentials(
                        String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    )
                    break
                }
            }
        }
        return GitIdentity(repositoryURL: repositoryURL, commit: commit, branch: branch)
    }

    private static func boundedFileData(_ url: URL, maximumBytes: Int) -> Data? {
        guard let info = fileInfo(url), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        return try? readAll(descriptor: descriptor, size: Int(info.st_size))
    }

    private static func redactURLCredentials(_ value: String) -> String {
        guard var components = URLComponents(string: value), components.user != nil || components.password != nil else {
            return bounded(value, maximumBytes: 4_096)
        }
        components.user = nil
        components.password = nil
        return bounded(components.string ?? value, maximumBytes: 4_096)
    }

    private static func initialHashState() -> Data {
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        return Data(bytes: &context, count: MemoryLayout<CC_SHA256_CTX>.size)
    }

    private static func updateHashState(_ state: Data, with data: Data) throws -> Data {
        guard state.count == MemoryLayout<CC_SHA256_CTX>.size else {
            throw StjornarvaldPolicySourceError.corruptState("unsupported SHA-256 cursor")
        }
        var context = CC_SHA256_CTX()
        _ = withUnsafeMutableBytes(of: &context) { state.copyBytes(to: $0) }
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress, !buffer.isEmpty {
                CC_SHA256_Update(&context, base, CC_LONG(buffer.count))
            }
        }
        return Data(bytes: &context, count: MemoryLayout<CC_SHA256_CTX>.size)
    }

    private static func finalizeHashState(_ state: Data) throws -> String {
        guard state.count == MemoryLayout<CC_SHA256_CTX>.size else {
            throw StjornarvaldPolicySourceError.corruptState("unsupported SHA-256 cursor")
        }
        var context = CC_SHA256_CTX()
        _ = withUnsafeMutableBytes(of: &context) { state.copyBytes(to: $0) }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func readAll(descriptor: Int32, size: Int) throws -> Data {
        guard size >= 0, size <= StjornarvaldNativePolicyExtractor.maximumInputBytes else {
            throw StjornarvaldPolicySourceError.invalidRequest("bounded extractor input exceeded")
        }
        var bytes = [UInt8](repeating: 0, count: size)
        var offset = 0
        while offset < size {
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.pread(
                    descriptor, base.advanced(by: offset), size - offset, off_t(offset)
                )
            }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += count
        }
        return Data(bytes)
    }

    private static func readPrefix(
        descriptor: Int32,
        maximumBytes: Int,
        fileSize: Int64
    ) throws -> Data {
        let requested = Int(min(Int64(max(maximumBytes, 0)), max(fileSize, 0)))
        guard requested > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: requested)
        let count = Darwin.pread(descriptor, &bytes, requested, 0)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(bytes.prefix(count))
    }

    private static func artifactID(revisionID: PolicySourceRevisionID, relativePath: String) -> PolicyArtifactID {
        PolicyArtifactID(deterministicUUID("artifact\u{0}\(revisionID.description)\u{0}\(relativePath)"))
    }

    private static func segmentID(artifactID: PolicyArtifactID, ordinal: Int) -> PolicySegmentID {
        PolicySegmentID(deterministicUUID("segment\u{0}\(artifactID.description)\u{0}\(ordinal)"))
    }

    private static func deterministicUUID(_ value: String) -> UUID {
        var characters = Array(JSONSupport.sha256Hex(value).prefix(32))
        characters[12] = "5"
        characters[16] = "8"
        let raw = String(characters)
        return UUID(uuidString: "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))")!
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var size = 0
        for character in value {
            let width = String(character).utf8.count
            if size + width > maximumBytes { break }
            result.append(character)
            size += width
        }
        return result
    }

    private func encodeStringMap(_ value: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw StjornarvaldPolicySourceError.corruptState("metadata encoding failed")
        }
        return result
    }

    private func decodeStringMap(_ value: String) throws -> [String: String] {
        guard let data = value.data(using: .utf8) else {
            throw StjornarvaldPolicySourceError.corruptState("metadata is not UTF-8")
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}
