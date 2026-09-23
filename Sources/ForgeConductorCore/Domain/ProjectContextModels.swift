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
    /// Provider-reported capacity remaining at the current tool boundary. A
    /// nil value means the host did not expose reliable usage for this turn.
    public let remainingContextTokens: Int?
    public let authorizationScope: ToolAuthorizationScope

    public init(
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        clientID: ClientID,
        runID: RunID? = nil,
        providerSessionID: String? = nil,
        runtimeJobID: UUID? = nil,
        remainingContextTokens: Int? = nil,
        authorizationScope: ToolAuthorizationScope
    ) {
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.clientID = clientID
        self.runID = runID
        self.providerSessionID = providerSessionID
        self.runtimeJobID = runtimeJobID
        self.remainingContextTokens = remainingContextTokens
        self.authorizationScope = authorizationScope
    }

    public func withRemainingContextTokens(_ value: Int?) -> ToolInvocationContext {
        ToolInvocationContext(
            projectID: projectID,
            projectGeneration: projectGeneration,
            clientID: clientID,
            runID: runID,
            providerSessionID: providerSessionID,
            runtimeJobID: runtimeJobID,
            remainingContextTokens: value,
            authorizationScope: authorizationScope
        )
    }
}

/// One short-lived, single-use authority delivered only through a desktop
/// provider's authenticated hook response. The raw token is never persisted;
/// the control plane retains only its digest until an MCP client consumes it.
public struct DesktopProviderMCPAttachmentCapability: Sendable, Equatable {
    public let token: String
    public let providerID: ProviderIntegrationID
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let sessionSHA256: String
    public let selectionRevision: String
    public let deploymentID: String
    public let expiresAt: String

    public var toolArguments: [String: Any] {
        [
            "attachment_token": token,
            "provider_id": providerID.rawValue,
            "run_id": runID.description,
            "project_id": projectID.description,
            "project_generation": Int(projectGeneration.rawValue),
            "session_sha256": sessionSHA256,
            "selection_revision": selectionRevision,
            "deployment_id": deploymentID,
        ]
    }
}

/// Exact public input for the context-free desktop MCP bootstrap tool. Every
/// non-secret identity is repeated so a copied token cannot be silently applied
/// to a different host session, run, project generation, or deployment.
public struct DesktopProviderMCPAttachmentRequest: Sendable, Equatable {
    public let token: String
    public let providerID: ProviderIntegrationID
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let sessionSHA256: String
    public let selectionRevision: String
    public let deploymentID: String

    public init(arguments: [String: Any]) throws {
        let expectedKeys: Set<String> = [
            "attachment_token", "provider_id", "run_id", "project_id",
            "project_generation", "session_sha256", "selection_revision",
            "deployment_id",
        ]
        guard Set(arguments.keys) == expectedKeys,
              let token = arguments["attachment_token"] as? String,
              Self.isLowercaseSHA256(token),
              let providerRaw = arguments["provider_id"] as? String,
              let providerID = ProviderIntegrationID(rawValue: providerRaw),
              Self.isSelectableDesktopProvider(providerID),
              let runRaw = arguments["run_id"] as? String,
              let runUUID = UUID(uuidString: runRaw),
              runRaw == runUUID.uuidString.lowercased(),
              let projectRaw = arguments["project_id"] as? String,
              let projectUUID = UUID(uuidString: projectRaw),
              projectRaw == projectUUID.uuidString.lowercased(),
              let generationValue = JSONSupport.exactInteger(arguments["project_generation"]),
              generationValue > 0,
              let generation = UInt64(exactly: generationValue),
              let sessionSHA256 = arguments["session_sha256"] as? String,
              Self.isLowercaseSHA256(sessionSHA256),
              let selectionRevision = arguments["selection_revision"] as? String,
              Self.validText(
                selectionRevision,
                maximumBytes: ProviderIntegrationContract.maximumRevisionBytes
              ),
              let deploymentID = arguments["deployment_id"] as? String,
              Self.validText(
                deploymentID,
                maximumBytes: ProviderIntegrationContract.maximumArtifactVersionBytes
              ) else {
            throw DesktopProviderMCPAttachmentError.invalidRequest
        }
        self.token = token
        self.providerID = providerID
        self.runID = RunID(runUUID)
        self.projectID = ProjectID(projectUUID)
        self.projectGeneration = ProjectGeneration(generation)
        self.sessionSHA256 = sessionSHA256
        self.selectionRevision = selectionRevision
        self.deploymentID = deploymentID
    }

    init(capability: DesktopProviderMCPAttachmentCapability) throws {
        try self.init(arguments: capability.toolArguments)
    }

    static func isSelectableDesktopProvider(_ providerID: ProviderIntegrationID) -> Bool {
        providerID == .claudeDesktop || providerID == .codexDesktop
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

public enum DesktopProviderMCPAttachmentError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest
    case unavailableForLaunchRole
    case attachmentRequired
    case rejected
    case expired
    case consumed
    case staleAuthority
    case clientConflict

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The desktop MCP attachment request is invalid."
        case .unavailableForLaunchRole:
            "Desktop MCP attachment is unavailable for this server role."
        case .attachmentRequired:
            "Attach this desktop provider session before using Forge MCP tools."
        case .rejected, .expired, .consumed, .staleAuthority:
            "The desktop MCP attachment authority is invalid, expired, consumed, or stale."
        case .clientConflict:
            "This MCP client already has a conflicting project binding."
        }
    }
}

enum DesktopProviderMCPAttachmentContract {
    static let toolName = "desktop_run_attach"
    static let capabilityLifetime: TimeInterval = 5 * 60
    static let capabilityMarkerPrefix = "desktop-attach-capability:v1:"
    static let attachedMarkerPrefix = "desktop-attachment:v1:"
    static let tokenByteCount = 32
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

public struct ProjectArchiveReceipt: Codable, Sendable, Equatable {
    public let projectID: ProjectID
    public let priorGeneration: ProjectGeneration
    public let archivedGeneration: ProjectGeneration
    public let invalidatedBindingCount: Int
    public let completedAt: String
    public let replayed: Bool

    public func asDictionary() -> [String: Any] {
        [
            "ok": true,
            "project_id": projectID.description,
            "prior_generation": priorGeneration.rawValue,
            "archived_generation": archivedGeneration.rawValue,
            "invalidated_binding_count": invalidatedBindingCount,
            "completed_at": completedAt,
            "replayed": replayed,
        ]
    }
}

public enum ProjectContentClearMode: String, Codable, Sendable, CaseIterable {
    case memory
    case continuity
    case memoryAndContinuity = "memory_and_continuity"
    case runHistory = "run_history"

    public var clearsMemory: Bool {
        self == .memory || self == .memoryAndContinuity
    }

    public var clearsContinuity: Bool {
        self == .continuity || self == .memoryAndContinuity
    }
}

public struct ProjectContentClearRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let projectID: ProjectID
    public let expectedGeneration: ProjectGeneration
    public let mode: ProjectContentClearMode

    public init(
        operationID: UUID,
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        mode: ProjectContentClearMode
    ) {
        self.operationID = operationID
        self.projectID = projectID
        self.expectedGeneration = expectedGeneration
        self.mode = mode
    }
}

public struct ProjectContentClearReceipt: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let projectID: ProjectID
    public let mode: ProjectContentClearMode
    public let priorGeneration: ProjectGeneration
    public let newGeneration: ProjectGeneration
    public let memoryRecordCount: Int
    public let continuityRecordCount: Int
    public let runHistoryCount: Int
    public let invalidatedBindingCount: Int
    public let completedAt: String
    public let replayed: Bool

    public func asDictionary() -> [String: Any] {
        [
            "ok": true,
            "operation_id": operationID.uuidString.lowercased(),
            "project_id": projectID.description,
            "mode": mode.rawValue,
            "prior_generation": priorGeneration.rawValue,
            "new_generation": newGeneration.rawValue,
            "memory_record_count": memoryRecordCount,
            "continuity_record_count": continuityRecordCount,
            "run_history_count": runHistoryCount,
            "invalidated_binding_count": invalidatedBindingCount,
            "completed_at": completedAt,
            "replayed": replayed,
        ]
    }
}

public enum ProjectContentClearState: String, Codable, Sendable {
    case prepared
    case committed
}

public struct ProjectContentClearOperation: Codable, Sendable, Equatable {
    public let request: ProjectContentClearRequest
    public let state: ProjectContentClearState
    public let receipt: ProjectContentClearReceipt?
    public let createdAt: String
    public let updatedAt: String
}

/// Durable result of moving an existing project identity to a new canonical
/// repository root. Relinking always advances the generation so no authority
/// issued for the prior root can be reused at the new location.
public struct ProjectRelinkReceipt: Codable, Sendable, Equatable {
    public let projectID: ProjectID
    public let priorCanonicalRoot: URL
    public let newCanonicalRoot: URL
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
    case projectRootNotAuthorized(URL)
    case projectNotFound(ProjectID)
    case projectRootAlreadyRegistered(String)
    case projectRelinkRequired(ProjectID)
    case projectRelinkBusy(ProjectID)
    case projectRemovalBusy(ProjectID)
    case projectRegistrationTargetChanged(ProjectID)
    case projectRepositoryIdentityMismatch(ProjectID)
    case projectRelinkTargetChanged(ProjectID)
    case projectTransitionConflict(ProjectID)
    case projectTransitionCoordinatorRequired
    case projectNotActive(ProjectLifecycleState)
    case projectContextRequired(ProjectBindingOwner)
    case projectScopeMismatch
    case staleProjectGeneration(expected: ProjectGeneration, actual: ProjectGeneration)
    case ownerAlreadyBound(ProjectBindingOwner)
    case resetNotPrepared(ProjectID)
    case retainedFilesystemRecovery(ProjectID)
    case resetCancellationFailed(ProjectID)
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
        case .projectRootNotAuthorized: "project_root_not_authorized"
        case .projectNotFound: "project_not_found"
        case .projectRootAlreadyRegistered: "project_root_already_registered"
        case .projectRelinkRequired: "project_relink_required"
        case .projectRelinkBusy: "project_relink_busy"
        case .projectRemovalBusy: "project_removal_busy"
        case .projectRegistrationTargetChanged: "project_registration_target_changed"
        case .projectRepositoryIdentityMismatch: "project_repository_identity_mismatch"
        case .projectRelinkTargetChanged: "project_relink_target_changed"
        case .projectTransitionConflict: "project_transition_conflict"
        case .projectTransitionCoordinatorRequired: "project_transition_coordinator_required"
        case .projectNotActive: "project_not_active"
        case .projectContextRequired: "project_context_required"
        case .projectScopeMismatch: "project_scope_mismatch"
        case .staleProjectGeneration: "stale_project_generation"
        case .ownerAlreadyBound: "binding_owner_conflict"
        case .resetNotPrepared: "project_reset_not_prepared"
        case .retainedFilesystemRecovery: "project_reset_filesystem_recovery_required"
        case .resetCancellationFailed: "project_reset_cancellation_failed"
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
        case .projectRootNotAuthorized(let root):
            "Project root is not authorized in Settings: \(root.path)"
        case .projectNotFound(let projectID):
            "Project not found: \(projectID)"
        case .projectRootAlreadyRegistered(let root):
            "Project root is already registered: \(root)"
        case .projectRelinkRequired(let projectID):
            "Project root changed and requires an explicit relink: \(projectID)"
        case .projectRelinkBusy(let projectID):
            "Project relink requires all project bindings and autonomous runs to be inactive: \(projectID)"
        case .projectRemovalBusy(let projectID):
            "Finish or cancel active autonomous runs before removing this project: \(projectID)"
        case .projectRegistrationTargetChanged(let projectID):
            "Project registration target changed after it was selected: \(projectID)"
        case .projectRepositoryIdentityMismatch(let projectID):
            "Project relink target does not match the registered repository identity: \(projectID)"
        case .projectRelinkTargetChanged(let projectID):
            "Project relink target changed after it was selected: \(projectID)"
        case .projectTransitionConflict(let projectID):
            "Another project transition owns the pending maintenance state: \(projectID)"
        case .projectTransitionCoordinatorRequired:
            "Project registration and relink require the manager-owned transition coordinator"
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
        case .retainedFilesystemRecovery(let projectID):
            "Project generation reset requires protected filesystem recovery first: \(projectID)"
        case .resetCancellationFailed(let projectID):
            "Project generation reset cleanup failed and requires operator recovery: \(projectID)"
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
