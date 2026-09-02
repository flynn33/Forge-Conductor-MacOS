// ProjectMemoryModels.swift
// What: Defines the versioned values and stable failures used by project memory.
// How: Compact Sendable models cross the service, repository, and MCP boundaries.
// Why: Project memory must remain typed, bounded, and independent of chat messages.

import Foundation

public enum ProjectMemoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case unsupportedVersion(Int)
    case projectNotFound(String)
    case projectScopeMismatch
    case recordNotFound(String)
    case conflict(String)
    case payloadTooLarge(String)
    case databaseBusy
    case storageFull
    case deadlineExceeded
    case cancelled
    case migrationFailed(String)
    case integrityFailure(String)
    case redactionRejected(String)

    public var code: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .unsupportedVersion: "unsupported_version"
        case .projectNotFound: "project_not_found"
        case .projectScopeMismatch: "project_scope_mismatch"
        case .recordNotFound: "record_not_found"
        case .conflict: "conflict"
        case .payloadTooLarge: "payload_too_large"
        case .databaseBusy: "database_busy"
        case .storageFull: "storage_full"
        case .deadlineExceeded: "deadline_exceeded"
        case .cancelled: "cancelled"
        case .migrationFailed: "migration_failed"
        case .integrityFailure: "integrity_failure"
        case .redactionRejected: "redaction_rejected"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let value), .projectNotFound(let value),
             .recordNotFound(let value), .conflict(let value),
             .payloadTooLarge(let value), .migrationFailed(let value),
             .integrityFailure(let value), .redactionRejected(let value): value
        case .unsupportedVersion(let version): "Unsupported schema version: \(version)"
        case .projectScopeMismatch: "Project identity does not match the opened memory store"
        case .databaseBusy: "Project memory database is busy"
        case .storageFull: "Project memory storage is full"
        case .deadlineExceeded: "Project memory request deadline exceeded"
        case .cancelled: "Project memory request was cancelled"
        }
    }
}

public struct ProjectMemoryLimits: Sendable, Equatable {
    public static let current = ProjectMemoryLimits()
    public let maximumTitleBytes = 512
    public let maximumSummaryBytes = 4 * 1024
    public let maximumBodyBytes = 256 * 1024
    public let maximumSourceReferenceBytes = 2 * 1024
    public let maximumTagCount = 32
    public let maximumTagBytes = 128
    public let maximumBatchCount = 50
    public let maximumBatchBytes = 1024 * 1024
    public let maximumQueryBytes = 4 * 1024
    public let maximumPageCount = 100
    public let defaultPageCount = 20
    public let maximumResponseBytes = 256 * 1024
    public let defaultResponseBytes = 64 * 1024
    public let maximumOpenProjects = 8

    public func asDictionary() -> [String: Any] {
        [
            "title_bytes": maximumTitleBytes,
            "summary_bytes": maximumSummaryBytes,
            "body_bytes": maximumBodyBytes,
            "source_reference_bytes": maximumSourceReferenceBytes,
            "tag_count": maximumTagCount,
            "tag_bytes": maximumTagBytes,
            "batch_count": maximumBatchCount,
            "batch_bytes": maximumBatchBytes,
            "page_count": maximumPageCount,
            "response_bytes": maximumResponseBytes,
            "open_projects": maximumOpenProjects,
        ]
    }
}

public struct ProjectMemoryDescriptor: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var repositoryIdentity: String?
    public var aliases: [String]

    public func asDictionary() -> [String: Any] {
        [
            "project_id": id,
            "display_name": displayName,
            "repository_identity": repositoryIdentity as Any,
            "aliases": aliases,
        ]
    }
}

/// Result of proving that a user-selected directory is another checkout or
/// location of an already registered Git repository. The identity is inferred
/// from the selected directory itself; callers cannot supply it.
struct ProjectDirectoryIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
}

/// One independently discovered filesystem target. The raw namespace path is
/// resolved exactly once; subsequent registration and relink transitions carry
/// this value rather than resolving caller-controlled path text again.
struct ProjectIdentityTarget: Sendable, Equatable {
    let canonicalRoot: URL
    let repositoryIdentity: String?
    let directoryIdentity: ProjectDirectoryIdentity
}

struct ProjectRegistrationIdentityPreparation: Sendable, Equatable {
    let operationID: String
    let descriptor: ProjectMemoryDescriptor
    let target: ProjectIdentityTarget
    /// Nil proves that no control-plane row existed when the candidate was
    /// captured. A value binds replay to that exact live generation.
    let expectedControlGeneration: ProjectGeneration?
    /// Nil accompanies an absent control row. A value prevents an unrelated
    /// maintenance transition from being mistaken for registration recovery.
    let expectedControlLifecycleState: ProjectLifecycleState?
    /// The fingerprint captured from the same control-plane generation. This
    /// distinguishes an exact no-op registration from a fenced legacy-null
    /// repository-identity adoption.
    let expectedControlRepositoryIdentity: String?
}

struct PendingProjectRegistrationIdentity: Sendable, Equatable {
    let preparation: ProjectRegistrationIdentityPreparation
    let requestedPath: String
    let requestedDisplayName: String?
    let repositoryIdentityAssertion: String?
    let createdAt: String
}

struct StagedProjectRegistrationIdentity: Sendable, Equatable {
    let pending: PendingProjectRegistrationIdentity
    let created: Bool
}

struct ProjectRelinkIdentityPreparation: Sendable, Equatable {
    let operationID: String
    let expectedGeneration: ProjectGeneration
    let descriptor: ProjectMemoryDescriptor
    let target: ProjectIdentityTarget

    var canonicalRoot: URL { target.canonicalRoot }
    var repositoryIdentity: String {
        // Relink discovery requires an existing repository identity.
        target.repositoryIdentity ?? ""
    }
}

struct PendingProjectRelinkIdentity: Sendable, Equatable {
    let preparation: ProjectRelinkIdentityPreparation
    let createdAt: String
}

enum ProjectRelinkIdentityRecovery: Sendable, Equatable {
    case none
    case abortedUncommitted(operationID: String)
    case publishedCommittedAlias(operationID: String)
}

public struct ProjectMemoryRecord: Sendable, Equatable {
    public var id: String
    public var projectID: String
    public var version: Int
    public var kind: String
    public var title: String
    public var summary: String
    public var body: String?
    public var tags: [String]
    public var importance: Double
    public var confidence: Double
    public var sourceKind: String
    public var sourceReference: String?
    public var sessionID: String?
    public var createdAt: String
    public var updatedAt: String
    public var lastAccessedAt: String
    public var expiresAt: String?
    public var contentHash: String
    public var isTombstone: Bool
    public var schemaVersion: Int

    public func asDictionary(includeBody: Bool = false, score: Double? = nil) -> [String: Any] {
        var output: [String: Any] = [
            "id": id,
            "project_id": projectID,
            "version": version,
            "kind": kind,
            "title": title,
            "summary": summary,
            "tags": tags,
            "importance": importance,
            "confidence": confidence,
            "source_kind": sourceKind,
            "source_reference": sourceReference as Any,
            "session_id": sessionID as Any,
            "created_at": createdAt,
            "updated_at": updatedAt,
            "last_accessed_at": lastAccessedAt,
            "expires_at": expiresAt as Any,
            "content_hash": contentHash,
            "is_tombstone": isTombstone,
            "schema_version": schemaVersion,
        ]
        if includeBody { output["body"] = body as Any }
        if let score { output["score"] = score }
        return output
    }
}

public struct ProjectMemoryWrite: Sendable {
    public var kind: String
    public var title: String
    public var summary: String
    public var body: String?
    public var tags: [String]
    public var importance: Double
    public var confidence: Double
    public var sourceKind: String
    public var sourceReference: String?
    public var sessionID: String?
    public var expiresAt: String?
    public var relatedIDs: [String]
    public var idempotencyKey: String?

    public init(
        kind: String,
        title: String,
        summary: String,
        body: String? = nil,
        tags: [String] = [],
        importance: Double = 0.5,
        confidence: Double = 1,
        sourceKind: String = "external_integration",
        sourceReference: String? = nil,
        sessionID: String? = nil,
        expiresAt: String? = nil,
        relatedIDs: [String] = [],
        idempotencyKey: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.body = body
        self.tags = tags
        self.importance = importance
        self.confidence = confidence
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.relatedIDs = relatedIDs
        self.idempotencyKey = idempotencyKey
    }
}
