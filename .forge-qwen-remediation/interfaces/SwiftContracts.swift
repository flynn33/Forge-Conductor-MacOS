import Foundation

// Blueprint contracts. Adapt names to the repository's existing domain types.

public struct GateValidationRequest: Sendable {
    public let executionID: String
    public let gateID: String
    public let validatorID: String
    public let validatorVersion: String
    public let projectID: String
    public let projectGeneration: Int64
    public let packageRunID: String?
    public let runID: String?
    public let sourceManifestSHA256: String
    public let parameters: Data
    public let deadline: ContinuousClock.Instant
}

public struct GateArtifactReceipt: Codable, Sendable, Equatable {
    public let role: String
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
}

public struct GateValidationReceipt: Codable, Sendable, Equatable {
    public let executionID: String
    public let gateID: String
    public let validatorID: String
    public let validatorVersion: String
    public let projectID: String
    public let projectGeneration: Int64
    public let packageRunID: String?
    public let runID: String?
    public let sourceManifestBefore: String
    public let sourceManifestAfter: String
    public let status: Status
    public let summary: String
    public let artifacts: [GateArtifactReceipt]
    public let startedAt: String
    public let endedAt: String
    public let receiptSHA256: String

    public enum Status: String, Codable, Sendable {
        case passed
        case failed
        case blockedEnvironment
        case cancelled
        case timedOut
    }
}

public protocol GateValidating: Sendable {
    var validatorID: String { get }
    var validatorVersion: String { get }
    func validate(_ request: GateValidationRequest) async throws -> GateValidationReceipt
}

public protocol GateRegistryProtocol: Sendable {
    func validator(id: String, version: String) async throws -> any GateValidating
    func definitions(forRunID runID: String) async throws -> [GateDefinitionRecord]
}

public struct GateDefinitionRecord: Codable, Sendable, Equatable {
    public let gateID: String
    public let revision: Int64
    public let validatorID: String
    public let validatorVersion: String
    public let parameters: Data
    public let timeoutSeconds: Int
    public let requiredPlatform: String
    public let mandatory: Bool
}

public enum ProjectResetMode: String, Codable, Sendable {
    case memory
    case continuity
    case memoryAndContinuity
    case runHistory
}

public struct ProjectResetRequest: Codable, Sendable {
    public let resetID: String
    public let projectID: String
    public let expectedGeneration: Int64
    public let mode: ProjectResetMode
    public let createBackup: Bool
    public let idempotencyKey: String
}

public struct QueueAssignment: Codable, Sendable, Equatable {
    public let assignmentID: String
    public let packageID: String
    public let packageDigest: String
    public let packageRunID: String
    public let runID: String?
    public let projectID: String
    public let projectGeneration: Int64
    public let leaseEpoch: Int64
    public let mission: String
    public let allowedTools: [String]
    public let canonicalRoots: [String]
    public let completionGateIDs: [String]
    public let artifactRoot: String
    public let issuedAt: String
    public let expiresAt: String
}

public enum RuntimeIsolationProfile: String, Codable, Sendable {
    case workspaceIsolated
    case hardenedXPC
}

public struct EffectiveResourcePolicy: Codable, Sendable, Equatable {
    public let revision: Int64
    public let profile: String
    public let memoryPressure: String
    public let maximumConcurrentRuns: Int
    public let maximumRuntimeJobs: Int
    public let telemetryHistoryPoints: Int
    public let visibleGaugeFPS: Int
    public let backgroundGaugeFPS: Int
    public let maximumInMemoryEvents: Int
    public let maximumProviderPayloadBytes: Int
}
