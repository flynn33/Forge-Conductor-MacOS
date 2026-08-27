// ProjectContextModels.swift
// Defines durable project identity, binding, authorization, and generation-fencing values.

import Foundation

public struct ProjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public struct ProjectGeneration: Hashable, Codable, Sendable, Comparable {
    public static let initial = ProjectGeneration(1)

    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ProjectGeneration, rhs: ProjectGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RunID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum ProjectLifecycleState: String, Codable, Sendable, CaseIterable {
    case active
    case maintenance
    case resetting
    case archived
    case quarantined
}

public enum ProjectBindingOwnerKind: String, Codable, Sendable, CaseIterable {
    case mcpClient = "mcp_client"
    case agentSession = "agent_session"
    case providerSession = "provider_session"
    case autonomousRun = "autonomous_run"
    case runtimeJob = "runtime_job"
    case guiSelection = "gui_selection"
}

public struct ProjectBindingOwner: Hashable, Codable, Sendable {
    public let kind: ProjectBindingOwnerKind
    public let id: String

    public init(kind: ProjectBindingOwnerKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

public struct ToolAuthorizationScope: Codable, Sendable, Equatable {
    /// Canonical roots visible to a tool invocation. These roots do not imply
    /// write authority; callers may grant a read-only scope by passing an empty
    /// `writableRoots` collection.
    public let canonicalRoots: [URL]
    public let writableRoots: [URL]
    public let allowedTools: Set<String>
    public let networkAllowed: Bool
    public let maximumInlineOutputBytes: Int

    public init(
        canonicalRoots: [URL],
        writableRoots: [URL]? = nil,
        allowedTools: Set<String>,
        networkAllowed: Bool,
        maximumInlineOutputBytes: Int
    ) {
        let normalizedReadRoots = canonicalRoots
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
        self.canonicalRoots = normalizedReadRoots
        self.writableRoots = (writableRoots ?? normalizedReadRoots)
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
        self.allowedTools = allowedTools
        self.networkAllowed = networkAllowed
        self.maximumInlineOutputBytes = maximumInlineOutputBytes
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalRoots
        case writableRoots
        case allowedTools
        case networkAllowed
        case maximumInlineOutputBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let readRoots = try container.decode([URL].self, forKey: .canonicalRoots)
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
        canonicalRoots = readRoots
        writableRoots = try container.decodeIfPresent([URL].self, forKey: .writableRoots)
            .map { roots in
                roots.map(\.standardizedFileURL).sorted { $0.path < $1.path }
            } ?? readRoots
        allowedTools = try container.decode(Set<String>.self, forKey: .allowedTools)
        networkAllowed = try container.decode(Bool.self, forKey: .networkAllowed)
        maximumInlineOutputBytes = try container.decode(
            Int.self,
            forKey: .maximumInlineOutputBytes
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalRoots, forKey: .canonicalRoots)
        try container.encode(writableRoots, forKey: .writableRoots)
        try container.encode(allowedTools, forKey: .allowedTools)
        try container.encode(networkAllowed, forKey: .networkAllowed)
        try container.encode(maximumInlineOutputBytes, forKey: .maximumInlineOutputBytes)
    }
}

public struct ToolInvocationContext: Codable, Sendable, Equatable {
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let clientID: ClientID
    public let runID: RunID?
    public let providerSessionID: String?
    public let runtimeJobID: UUID?
    public let authorizationScope: ToolAuthorizationScope

    public init(
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        clientID: ClientID,
        runID: RunID? = nil,
        providerSessionID: String? = nil,
        runtimeJobID: UUID? = nil,
        authorizationScope: ToolAuthorizationScope
    ) {
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.clientID = clientID
        self.runID = runID
        self.providerSessionID = providerSessionID
        self.runtimeJobID = runtimeJobID
        self.authorizationScope = authorizationScope
    }
}

public struct ProjectControlRecord: Codable, Sendable, Equatable {
    public let projectID: ProjectID
    public let displayName: String
    public let canonicalRoot: URL
    public let generation: ProjectGeneration
    public let lifecycleState: ProjectLifecycleState
    public let repositoryFingerprint: String?
    public let bookmarkReference: String?
    public let createdAt: String
    public let updatedAt: String
}

public struct ProjectContextBinding: Codable, Sendable, Equatable {
    public let bindingID: UUID
    public let owner: ProjectBindingOwner
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let runID: RunID?
    public let authorizationScope: ToolAuthorizationScope
    public let leaseOwner: String?
    public let leaseExpiresAt: String?
    public let active: Bool
    public let createdAt: String
    public let updatedAt: String

    public func invocationContext(clientID: ClientID) -> ToolInvocationContext {
        ToolInvocationContext(
            projectID: projectID,
            projectGeneration: projectGeneration,
            clientID: clientID,
            runID: runID,
            providerSessionID: owner.kind == .providerSession ? owner.id : nil,
            runtimeJobID: owner.kind == .runtimeJob ? UUID(uuidString: owner.id) : nil,
            authorizationScope: authorizationScope
        )
    }
}

public struct ProjectGenerationResetReceipt: Codable, Sendable, Equatable {
    public let projectID: ProjectID
    public let priorGeneration: ProjectGeneration
    public let newGeneration: ProjectGeneration
    public let invalidatedBindingCount: Int
    public let completedAt: String
}

public struct ControlPlaneDatabaseHealth: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let journalMode: String
    public let foreignKeysEnabled: Bool
    public let busyTimeoutMilliseconds: Int
    public let integrityResult: String
}

public enum ProjectContextError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidGeneration(UInt64)
    case invalidAuthorizationScope(String)
    case projectNotFound(ProjectID)
    case projectRootAlreadyRegistered(String)
    case projectRelinkRequired(ProjectID)
    case projectNotActive(ProjectLifecycleState)
    case projectContextRequired(ProjectBindingOwner)
    case projectScopeMismatch
    case staleProjectGeneration(expected: ProjectGeneration, actual: ProjectGeneration)
    case ownerAlreadyBound(ProjectBindingOwner)
    case resetNotPrepared(ProjectID)
    case unsupportedSchemaVersion(Int)
    case databaseBusy
    case storageFull
    case integrityFailure(String)
    case databaseFailure(String)
    case repositoryClosed

    public var code: String {
        switch self {
        case .invalidIdentifier: "invalid_identifier"
        case .invalidGeneration: "invalid_project_generation"
        case .invalidAuthorizationScope: "invalid_authorization_scope"
        case .projectNotFound: "project_not_found"
        case .projectRootAlreadyRegistered: "project_root_already_registered"
        case .projectRelinkRequired: "project_relink_required"
        case .projectNotActive: "project_not_active"
        case .projectContextRequired: "project_context_required"
        case .projectScopeMismatch: "project_scope_mismatch"
        case .staleProjectGeneration: "stale_project_generation"
        case .ownerAlreadyBound: "binding_owner_conflict"
        case .resetNotPrepared: "project_reset_not_prepared"
        case .unsupportedSchemaVersion: "unsupported_schema_version"
        case .databaseBusy: "database_busy"
        case .storageFull: "storage_full"
        case .integrityFailure: "integrity_failure"
        case .databaseFailure: "database_failure"
        case .repositoryClosed: "repository_closed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            "Invalid durable identifier: \(value)"
        case .invalidGeneration(let value):
            "Invalid project generation: \(value)"
        case .invalidAuthorizationScope(let reason):
            "Invalid authorization scope: \(reason)"
        case .projectNotFound(let projectID):
            "Project not found: \(projectID)"
        case .projectRootAlreadyRegistered(let root):
            "Project root is already registered: \(root)"
        case .projectRelinkRequired(let projectID):
            "Project root changed and requires an explicit relink: \(projectID)"
        case .projectNotActive(let state):
            "Project is not active: \(state.rawValue)"
        case .projectContextRequired(let owner):
            "No active project context is bound to \(owner.kind.rawValue):\(owner.id)"
        case .projectScopeMismatch:
            "Invocation context does not match its durable binding"
        case .staleProjectGeneration(let expected, let actual):
            "Project generation is stale: expected \(expected.rawValue), current \(actual.rawValue)"
        case .ownerAlreadyBound(let owner):
            "Binding owner is already active: \(owner.kind.rawValue):\(owner.id)"
        case .resetNotPrepared(let projectID):
            "Project reset is not prepared: \(projectID)"
        case .unsupportedSchemaVersion(let version):
            "Unsupported control-plane schema version: \(version)"
        case .databaseBusy:
            "Control-plane database is busy"
        case .storageFull:
            "Control-plane storage is full"
        case .integrityFailure(let reason):
            "Control-plane integrity check failed: \(reason)"
        case .databaseFailure(let reason):
            "Control-plane database error: \(reason)"
        case .repositoryClosed:
            "Control-plane repository is closed"
        }
    }
}
