// ProviderIntegrationModels.swift
// What: Defines provider-selection, setup-operation, and adapter contracts.
// How: Bounded value models separate managed inference from desktop-host orchestration.
// Why: Provider switching must be durable, mutually exclusive, and safe to expose over the manager API.

import Foundation

public enum ProviderIntegrationContract {
    public static let maximumRevisionBytes = 128
    public static let maximumIdempotencyKeyBytes = 256
    public static let maximumOperationIDBytes = 128
    public static let maximumDetailBytes = 2_048
    public static let maximumArtifactVersionBytes = 128
    public static let maximumMetadataEntries = 32
    public static let maximumMetadataKeyBytes = 128
    public static let maximumMetadataValueBytes = 2_048
    public static let maximumRecentOperations = 32
    public static let maximumLedgerBytes = 512 * 1_024

    static func validateText(
        _ value: String,
        field: String,
        maximumBytes: Int,
        permitsEmpty: Bool = false
    ) throws {
        guard (permitsEmpty || !value.isEmpty), value.utf8.count <= maximumBytes else {
            throw ProviderIntegrationError.invalidRequest(
                field: field,
                reason: "empty_or_oversized"
            )
        }
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ProviderIntegrationError.invalidRequest(
                field: field,
                reason: "contains_control_characters"
            )
        }
    }

    static func validateSHA256(_ value: String, field: String) throws {
        guard value.utf8.count == 64,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw ProviderIntegrationError.invalidRequest(
                field: field,
                reason: "expected_lowercase_sha256"
            )
        }
    }
}

/// Stable product identifiers. LM Studio executes managed model turns; the
/// desktop products are external execution hosts that pull Forge orchestration.
public enum ProviderIntegrationID: String, Codable, Sendable, CaseIterable {
    case lmStudio = "lmstudio"
    case claudeDesktop = "claude-desktop"
    case codexDesktop = "codex-desktop"
    case grokBuild = "grok-build"
}

public enum ProviderExecutionStrategy: String, Codable, Sendable {
    case managedProviderPush = "managed_provider_push"
    case desktopPluginPull = "desktop_plugin_pull"
}

public struct ProviderIntegrationDescriptor: Codable, Sendable, Equatable {
    public let id: ProviderIntegrationID
    public let displayName: String
    public let executionStrategy: ProviderExecutionStrategy
    public let selectable: Bool
    public let detail: String

    public init(
        id: ProviderIntegrationID,
        displayName: String,
        executionStrategy: ProviderExecutionStrategy,
        selectable: Bool = true,
        detail: String
    ) {
        self.id = id
        self.displayName = displayName
        self.executionStrategy = executionStrategy
        self.selectable = selectable
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case executionStrategy = "execution_strategy"
        case selectable
        case detail
    }

    public static let supported: [ProviderIntegrationDescriptor] = [
        .init(
            id: .lmStudio,
            displayName: "LM Studio",
            executionStrategy: .managedProviderPush,
            detail: "Forge sends bounded managed-model turns to LM Studio."
        ),
        .init(
            id: .claudeDesktop,
            displayName: "Claude Code Desktop",
            executionStrategy: .desktopPluginPull,
            detail: "Claude Code Desktop executes work through a Forge-managed plugin."
        ),
        .init(
            id: .codexDesktop,
            displayName: "Codex Desktop",
            executionStrategy: .desktopPluginPull,
            detail: "Codex Desktop executes work through a Forge-managed plugin."
        ),
        .init(
            id: .grokBuild,
            displayName: "Grok Build",
            executionStrategy: .desktopPluginPull,
            selectable: false,
            detail: "Grok Build is detected for cleanup and future compatibility, but its current hook protocol cannot deliver assignment context to the model reliably."
        ),
    ]
}

public enum ProviderIntegrationSetupState: String, Codable, Sendable {
    case notConfigured = "not_configured"
    case configured
}

/// A redacted receipt for artifacts owned by Forge. It contains no credential
/// material and is retained when the provider is merely deactivated.
public struct ProviderIntegrationReceipt: Codable, Sendable, Equatable {
    public let providerID: ProviderIntegrationID
    public let artifactVersion: String
    public let installedAt: String
    public let verifiedAt: String
    public let metadata: [String: String]

    public init(
        providerID: ProviderIntegrationID,
        artifactVersion: String,
        installedAt: String,
        verifiedAt: String,
        metadata: [String: String] = [:]
    ) throws {
        try ProviderIntegrationContract.validateText(
            artifactVersion,
            field: "artifact_version",
            maximumBytes: ProviderIntegrationContract.maximumArtifactVersionBytes
        )
        guard ISO8601.date(from: installedAt) != nil,
              ISO8601.date(from: verifiedAt) != nil else {
            throw ProviderIntegrationError.invalidRequest(
                field: "receipt_timestamp",
                reason: "expected_iso8601"
            )
        }
        guard metadata.count <= ProviderIntegrationContract.maximumMetadataEntries else {
            throw ProviderIntegrationError.invalidRequest(
                field: "metadata",
                reason: "too_many_entries"
            )
        }
        for (key, value) in metadata {
            try ProviderIntegrationContract.validateText(
                key,
                field: "metadata_key",
                maximumBytes: ProviderIntegrationContract.maximumMetadataKeyBytes
            )
            try ProviderIntegrationContract.validateText(
                value,
                field: "metadata_value",
                maximumBytes: ProviderIntegrationContract.maximumMetadataValueBytes,
                permitsEmpty: true
            )
        }
        self.providerID = providerID
        self.artifactVersion = artifactVersion
        self.installedAt = installedAt
        self.verifiedAt = verifiedAt
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case artifactVersion = "artifact_version"
        case installedAt = "installed_at"
        case verifiedAt = "verified_at"
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: try container.decode(ProviderIntegrationID.self, forKey: .providerID),
            artifactVersion: try container.decode(String.self, forKey: .artifactVersion),
            installedAt: try container.decode(String.self, forKey: .installedAt),
            verifiedAt: try container.decode(String.self, forKey: .verifiedAt),
            metadata: try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        )
    }
}

public struct ProviderIntegrationProviderSnapshot: Codable, Sendable, Equatable {
    public let descriptor: ProviderIntegrationDescriptor
    public let setupState: ProviderIntegrationSetupState
    public let receipt: ProviderIntegrationReceipt?

    public init(
        descriptor: ProviderIntegrationDescriptor,
        receipt: ProviderIntegrationReceipt?
    ) {
        self.descriptor = descriptor
        self.setupState = receipt == nil ? .notConfigured : .configured
        self.receipt = receipt
    }

    enum CodingKeys: String, CodingKey {
        case descriptor
        case setupState = "setup_state"
        case receipt
    }
}

public enum ProviderIntegrationOperationKind: String, Codable, Sendable {
    case activate
    case deactivate
    case repair
    case remove
}

public enum ProviderIntegrationOperationPhase: String, Codable, Sendable {
    case accepted
    case inspectingHost = "inspecting_host"
    case verifyingBridge = "verifying_bridge"
    case staging
    case committing
    case activatingHost = "activating_host"
    case verifyingConfiguration = "verifying_configuration"
    case awaitingUserAction = "awaiting_user_action"
    case active
    case completed
    case removed
    case rollingBack = "rolling_back"
    case failedRecoverable = "failed_recoverable"
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .awaitingUserAction, .active, .completed, .removed,
             .failedRecoverable, .cancelled:
            true
        default:
            false
        }
    }

    public var succeeded: Bool {
        self == .active || self == .completed || self == .removed
    }
}

public struct ProviderIntegrationOperationSnapshot: Codable, Sendable, Equatable {
    public let operationID: String
    public let kind: ProviderIntegrationOperationKind
    public let providerID: ProviderIntegrationID?
    public let phase: ProviderIntegrationOperationPhase
    public let expectedRevision: String
    public let resultingRevision: String?
    public let idempotencyKeySHA256: String
    public let intentSHA256: String
    public let detail: String?
    public let errorCode: String?
    public let acceptedAt: String
    public let updatedAt: String
    public let completedAt: String?

    public var isTerminal: Bool { phase.isTerminal }

    init(
        operationID: String,
        kind: ProviderIntegrationOperationKind,
        providerID: ProviderIntegrationID?,
        phase: ProviderIntegrationOperationPhase,
        expectedRevision: String,
        resultingRevision: String? = nil,
        idempotencyKeySHA256: String,
        intentSHA256: String,
        detail: String? = nil,
        errorCode: String? = nil,
        acceptedAt: String,
        updatedAt: String,
        completedAt: String? = nil
    ) {
        self.operationID = operationID
        self.kind = kind
        self.providerID = providerID
        self.phase = phase
        self.expectedRevision = expectedRevision
        self.resultingRevision = resultingRevision
        self.idempotencyKeySHA256 = idempotencyKeySHA256
        self.intentSHA256 = intentSHA256
        self.detail = detail
        self.errorCode = errorCode
        self.acceptedAt = acceptedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case kind
        case providerID = "provider_id"
        case phase
        case expectedRevision = "expected_revision"
        case resultingRevision = "resulting_revision"
        case idempotencyKeySHA256 = "idempotency_key_sha256"
        case intentSHA256 = "intent_sha256"
        case detail
        case errorCode = "error_code"
        case acceptedAt = "accepted_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }
}

public struct ProviderIntegrationsSnapshot: Codable, Sendable, Equatable {
    public let selectionRevision: String
    public let selectedProviderID: ProviderIntegrationID?
    public let providers: [ProviderIntegrationProviderSnapshot]
    public let currentOperation: ProviderIntegrationOperationSnapshot?
    public let recentOperations: [ProviderIntegrationOperationSnapshot]

    public init(
        selectionRevision: String,
        selectedProviderID: ProviderIntegrationID?,
        providers: [ProviderIntegrationProviderSnapshot],
        currentOperation: ProviderIntegrationOperationSnapshot?,
        recentOperations: [ProviderIntegrationOperationSnapshot]
    ) {
        self.selectionRevision = selectionRevision
        self.selectedProviderID = selectedProviderID
        self.providers = providers
        self.currentOperation = currentOperation
        self.recentOperations = recentOperations
    }

    enum CodingKeys: String, CodingKey {
        case selectionRevision = "selection_revision"
        case selectedProviderID = "selected_provider_id"
        case providers
        case currentOperation = "current_operation"
        case recentOperations = "recent_operations"
    }
}

public struct ProviderSelectionRequest: Codable, Sendable, Equatable {
    public let expectedRevision: String
    public let providerID: ProviderIntegrationID?
    public let idempotencyKey: String

    public init(
        expectedRevision: String,
        providerID: ProviderIntegrationID?,
        idempotencyKey: String
    ) throws {
        try ProviderIntegrationContract.validateText(
            expectedRevision,
            field: "expected_revision",
            maximumBytes: ProviderIntegrationContract.maximumRevisionBytes
        )
        try ProviderIntegrationContract.validateText(
            idempotencyKey,
            field: "idempotency_key",
            maximumBytes: ProviderIntegrationContract.maximumIdempotencyKeyBytes
        )
        self.expectedRevision = expectedRevision
        self.providerID = providerID
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case providerID = "provider_id"
        case idempotencyKey = "idempotency_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            expectedRevision: try container.decode(String.self, forKey: .expectedRevision),
            providerID: try container.decodeIfPresent(ProviderIntegrationID.self, forKey: .providerID),
            idempotencyKey: try container.decode(String.self, forKey: .idempotencyKey)
        )
    }
}

public struct ProviderIntegrationMutationRequest: Codable, Sendable, Equatable {
    public let expectedRevision: String
    public let providerID: ProviderIntegrationID
    public let idempotencyKey: String

    public init(
        expectedRevision: String,
        providerID: ProviderIntegrationID,
        idempotencyKey: String
    ) throws {
        try ProviderIntegrationContract.validateText(
            expectedRevision,
            field: "expected_revision",
            maximumBytes: ProviderIntegrationContract.maximumRevisionBytes
        )
        try ProviderIntegrationContract.validateText(
            idempotencyKey,
            field: "idempotency_key",
            maximumBytes: ProviderIntegrationContract.maximumIdempotencyKeyBytes
        )
        self.expectedRevision = expectedRevision
        self.providerID = providerID
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case providerID = "provider_id"
        case idempotencyKey = "idempotency_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            expectedRevision: try container.decode(String.self, forKey: .expectedRevision),
            providerID: try container.decode(ProviderIntegrationID.self, forKey: .providerID),
            idempotencyKey: try container.decode(String.self, forKey: .idempotencyKey)
        )
    }
}

public enum ProviderIntegrationInspectionState: String, Codable, Sendable {
    case ready
    case requiresProvisioning = "requires_provisioning"
    case awaitingUserAction = "awaiting_user_action"
}

public struct ProviderIntegrationInspection: Sendable, Equatable {
    public let state: ProviderIntegrationInspectionState
    public let detail: String
    public let receipt: ProviderIntegrationReceipt?

    public init(
        state: ProviderIntegrationInspectionState,
        detail: String,
        receipt: ProviderIntegrationReceipt? = nil
    ) throws {
        try ProviderIntegrationContract.validateText(
            detail,
            field: "inspection_detail",
            maximumBytes: ProviderIntegrationContract.maximumDetailBytes,
            permitsEmpty: true
        )
        if state == .ready, receipt == nil {
            throw ProviderIntegrationError.invalidAdapterResult(
                reason: "ready_inspection_requires_receipt"
            )
        }
        self.state = state
        self.detail = detail
        self.receipt = receipt
    }
}

public enum ProviderIntegrationAdapterResultState: String, Sendable {
    case ready
    case awaitingUserAction = "awaiting_user_action"
}

public struct ProviderIntegrationAdapterResult: Sendable, Equatable {
    public let state: ProviderIntegrationAdapterResultState
    public let detail: String
    public let receipt: ProviderIntegrationReceipt?

    public init(
        state: ProviderIntegrationAdapterResultState,
        detail: String,
        receipt: ProviderIntegrationReceipt? = nil
    ) throws {
        try ProviderIntegrationContract.validateText(
            detail,
            field: "adapter_detail",
            maximumBytes: ProviderIntegrationContract.maximumDetailBytes,
            permitsEmpty: true
        )
        if state == .ready, receipt == nil {
            throw ProviderIntegrationError.invalidAdapterResult(
                reason: "ready_result_requires_receipt"
            )
        }
        self.state = state
        self.detail = detail
        self.receipt = receipt
    }
}

public struct ProviderIntegrationAdapterRequest: Sendable, Equatable {
    public let operationID: String
    public let kind: ProviderIntegrationOperationKind
    public let existingReceipt: ProviderIntegrationReceipt?

    public init(
        operationID: String,
        kind: ProviderIntegrationOperationKind,
        existingReceipt: ProviderIntegrationReceipt?
    ) {
        self.operationID = operationID
        self.kind = kind
        self.existingReceipt = existingReceipt
    }
}

public struct ProviderIntegrationRemovalResult: Sendable, Equatable {
    public let state: ProviderIntegrationAdapterResultState
    public let detail: String

    public init(
        state: ProviderIntegrationAdapterResultState,
        detail: String
    ) throws {
        try ProviderIntegrationContract.validateText(
            detail,
            field: "adapter_detail",
            maximumBytes: ProviderIntegrationContract.maximumDetailBytes,
            permitsEmpty: true
        )
        self.state = state
        self.detail = detail
    }
}

/// Implementations own only Forge-created plugin/configuration artifacts. They
/// must preserve unrelated host settings and honor task cancellation promptly.
public protocol ProviderIntegrationAdapting: Sendable {
    var providerID: ProviderIntegrationID { get }
    func inspect(operationID: String) async throws -> ProviderIntegrationInspection
    func provision(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult
    func repair(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult
    func remove(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationRemovalResult
    func cancel(operationID: String) async
}

public enum ProviderIntegrationError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(field: String, reason: String)
    case invalidAdapterResult(reason: String)
    case revisionConflict(expected: String, actual: String)
    case idempotencyConflict
    case operationBusy(operationID: String)
    case providerHasNonterminalRuns(providerID: ProviderIntegrationID)
    case providerNotReady(providerID: ProviderIntegrationID)
    case adapterUnavailable(providerID: ProviderIntegrationID)
    case providerNotSelectable(providerID: ProviderIntegrationID)
    case selectedProviderCannotBeRemoved(providerID: ProviderIntegrationID)
    case operationNotFound(operationID: String)
    case operationNotCancellable(operationID: String)
    case ledgerCorrupt(reason: String)
    case persistenceFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let field, let reason):
            "Invalid provider integration request field \(field): \(reason)."
        case .invalidAdapterResult(let reason):
            "Provider integration adapter returned an invalid result: \(reason)."
        case .revisionConflict(let expected, let actual):
            "Provider selection changed (expected \(expected), current \(actual))."
        case .idempotencyConflict:
            "The idempotency key was already used for a different provider operation."
        case .operationBusy(let operationID):
            "Provider operation \(operationID) is still in progress."
        case .providerHasNonterminalRuns(let providerID):
            "Finish or cancel every active \(providerID.rawValue) task before changing this provider integration."
        case .providerNotReady(let providerID):
            "Provider \(providerID.rawValue) is not ready. Run Connect and Check, resolve the reported action, then select it again."
        case .adapterUnavailable(let providerID):
            "No integration adapter is registered for \(providerID.rawValue)."
        case .providerNotSelectable(let providerID):
            "Provider \(providerID.rawValue) is not selectable."
        case .selectedProviderCannotBeRemoved(let providerID):
            "Deactivate \(providerID.rawValue) before removing its Forge integration."
        case .operationNotFound(let operationID):
            "Provider operation \(operationID) was not found."
        case .operationNotCancellable(let operationID):
            "Provider operation \(operationID) is no longer cancellable."
        case .ledgerCorrupt(let reason):
            "Provider integration ledger is invalid: \(reason)."
        case .persistenceFailed(let reason):
            "Provider integration state could not be persisted: \(reason)."
        }
    }
}
