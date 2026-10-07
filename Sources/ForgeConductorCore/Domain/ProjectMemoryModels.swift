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
    public let maximumExpiryBytes = ProjectMemoryExpiry.maximumBytes
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
            "expiry_bytes": maximumExpiryBytes,
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

public enum ProjectMemoryImportExpiryPolicy: String, CaseIterable, Sendable {
    case strict
    case preserveLegacyV1 = "preserve_legacy_v1"
}

/// Expiry timestamps use bounded RFC 3339 calendar dates with an explicit zone.
/// Explicit legacy import preserves malformed values as non-expiring metadata.
enum ProjectMemoryExpiry {
    static let maximumBytes = 35

    static func normalized(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.utf8.count <= maximumBytes else {
            throw ProjectMemoryError.payloadTooLarge("expires_at exceeds \(maximumBytes) bytes")
        }
        guard let parsed = parse(raw) else {
            throw ProjectMemoryError.invalidRequest(
                "expires_at must be a calendar timestamp with an explicit timezone, seconds 00–59 and up to 9 fractional digits"
            )
        }
        return parsed.canonical
    }

    static func epoch(_ raw: String) -> Double? { parse(raw)?.epoch }

    static func normalizedForImport(_ raw: String?, policy: ProjectMemoryImportExpiryPolicy) throws -> String? {
        guard policy == .preserveLegacyV1, let raw else { return try normalized(raw) }
        return parse(raw)?.canonical ?? raw
    }

    private static func parse(_ raw: String) -> (epoch: Double, canonical: String)? {
        guard (20...maximumBytes).contains(raw.utf8.count) else { return nil }
        let bytes = Array(raw.utf8)
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 116,
              bytes[13] == 58, bytes[16] == 58 else { return nil }
        func digits(_ start: Int, _ length: Int) -> Int? {
            guard start + length <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<(start + length)] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = digits(0, 4), (1...9999).contains(year),
              let month = digits(5, 2), (1...12).contains(month),
              let day = digits(8, 2), (1...31).contains(day),
              let hour = digits(11, 2), (0...23).contains(hour),
              let minute = digits(14, 2), (0...59).contains(minute),
              let second = digits(17, 2), (0...59).contains(second) else { return nil }
        let leapYear = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let monthDays = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= monthDays[month - 1] else { return nil }
        var zoneStart = 19
        var fraction = ""
        if bytes[zoneStart] == 46 {
            zoneStart += 1
            let start = zoneStart
            while zoneStart < bytes.count, (48...57).contains(bytes[zoneStart]) { zoneStart += 1 }
            guard (1...9).contains(zoneStart - start) else { return nil }
            fraction = String(decoding: bytes[start..<zoneStart], as: UTF8.self)
        }
        guard zoneStart < bytes.count else { return nil }
        let zoneSeconds: Int
        if (bytes[zoneStart] == 90 || bytes[zoneStart] == 122), bytes.count == zoneStart + 1 {
            zoneSeconds = 0
        } else {
            guard bytes.count == zoneStart + 6,
                  bytes[zoneStart] == 43 || bytes[zoneStart] == 45,
                  bytes[zoneStart + 3] == 58,
                  let zoneHour = digits(zoneStart + 1, 2), (0...23).contains(zoneHour),
                  let zoneMinute = digits(zoneStart + 4, 2), (0...59).contains(zoneMinute) else { return nil }
            zoneSeconds = (zoneHour * 3600 + zoneMinute * 60) * (bytes[zoneStart] == 45 ? -1 : 1)
        }
        guard let zone = TimeZone(secondsFromGMT: zoneSeconds) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        guard let wholeDate = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wholeDate)
        guard check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute, check.second == second else { return nil }
        let subsecond = fraction.isEmpty ? 0 : Double("0." + fraction) ?? 0
        while fraction.last == "0" { fraction.removeLast() }
        let wholeUTC = ISO8601.string(from: wholeDate)
        guard wholeUTC.utf8.count == 20, wholeUTC.hasSuffix("Z"),
              !wholeUTC.hasPrefix("0000") else { return nil }
        let canonical = fraction.isEmpty ? wholeUTC : String(wholeUTC.dropLast()) + "." + fraction + "Z"
        return (wholeDate.addingTimeInterval(subsecond).timeIntervalSince1970, canonical)
    }
}

public struct ProjectMemoryPagePosition: Sendable {
    let id: String
    let updatedAt: String
    let rank: Double?
}

public struct ProjectMemoryDescriptor: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var repositoryIdentity: String?
    public var aliases: [String]
    public var githubRepositoryURL: String? = nil

    public func asDictionary() -> [String: Any] {
        [
            "project_id": id,
            "display_name": displayName,
            "repository_identity": repositoryIdentity as Any,
            "aliases": aliases,
            "github_repository_url": githubRepositoryURL as Any,
        ]
    }
}

/// Operator-entered repository metadata. It does not grant access or replace
/// the independently discovered repository identity used by registration.
public enum GitHubRepositoryLocation {
    public static let maximumBytes = 2_048

    public static func normalized(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= maximumBytes else {
            throw ProjectMemoryError.payloadTooLarge("GitHub repository location exceeds 2048 bytes")
        }
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else {
            guard let components = URLComponents(string: value),
                  components.host?.lowercased() == "github.com",
                  components.port == nil,
                  components.password == nil,
                  components.query == nil, components.fragment == nil,
                  (components.scheme?.lowercased() == "https" && components.user == nil)
                    || (components.scheme?.lowercased() == "ssh" && components.user == "git"),
                  components.percentEncodedPath == components.path,
                  components.path.hasPrefix("/") else {
                throw ProjectMemoryError.invalidRequest(
                    "Enter a GitHub repository URL such as https://github.com/owner/repository"
                )
            }
            path = String(components.path.dropFirst())
        }
        var repositoryPath = path
        if repositoryPath.hasSuffix("/") { repositoryPath.removeLast() }
        if repositoryPath.hasSuffix(".git") { repositoryPath.removeLast(4) }
        let segments = repositoryPath.split(separator: "/", omittingEmptySubsequences: false)
        let ownerCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let repositoryCharacters = ownerCharacters.union(CharacterSet(charactersIn: "_."))
        guard segments.count == 2,
              (1...39).contains(segments[0].utf8.count),
              segments[0].first != "-", segments[0].last != "-",
              !segments[0].contains("--"),
              segments[0].unicodeScalars.allSatisfy(ownerCharacters.contains),
              (1...100).contains(segments[1].utf8.count),
              segments[1] != ".", segments[1] != "..",
              segments[1].unicodeScalars.allSatisfy(repositoryCharacters.contains) else {
            throw ProjectMemoryError.invalidRequest("GitHub location must name one owner and repository")
        }
        return "https://github.com/\(segments[0])/\(segments[1])"
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

public struct ProjectMemoryContentClearReceipt: Sendable, Equatable {
    public let operationID: UUID
    public let projectID: String
    public let mode: ProjectContentClearMode
    public let memoryRecordCount: Int
    public let continuityRecordCount: Int
    public let committedAt: String
    public let replayed: Bool
}
