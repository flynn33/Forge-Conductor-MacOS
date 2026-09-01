// OperatorConsoleModels.swift
// Typed, bounded projections returned by the manager's native operator endpoint.

import Foundation

struct OperatorSnapshot: Decodable, Sendable, Equatable {
    let projects: [OperatorProject]
    let pendingProjectRegistrations: [OperatorProjectRegistrationTransition]
    let runs: [OperatorRun]
    let continuityOperations: [OperatorContinuity]
    let runtimeJobs: [OperatorRuntimeJob]
    let provider: OperatorProvider?
    let runtime: OperatorRuntimePolicy?
    let events: [OperatorEvent]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case projects, runs, provider, runtime, events
        case pendingProjectRegistrations = "pending_project_registrations"
        case continuityOperations = "continuity_operations"
        case runtimeJobs = "runtime_jobs"
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([OperatorProject].self, forKey: .projects) ?? []
        pendingProjectRegistrations = try container.decodeIfPresent(
            [OperatorProjectRegistrationTransition].self,
            forKey: .pendingProjectRegistrations
        ) ?? []
        runs = try container.decodeIfPresent([OperatorRun].self, forKey: .runs) ?? []
        continuityOperations = try container.decodeIfPresent(
            [OperatorContinuity].self,
            forKey: .continuityOperations
        ) ?? []
        runtimeJobs = try container.decodeIfPresent([OperatorRuntimeJob].self, forKey: .runtimeJobs) ?? []
        provider = try container.decodeIfPresent(OperatorProvider.self, forKey: .provider)
        runtime = try container.decodeIfPresent(OperatorRuntimePolicy.self, forKey: .runtime)
        events = try container.decodeIfPresent([OperatorEvent].self, forKey: .events) ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct OperatorProjectRegistrationTransition: Decodable, Sendable, Equatable {
    let projectID: String
    let state: String
    let requestPath: String
    let requestedDisplayName: String?
    let repositoryIdentityAssertion: String?
    let operationID: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case state
        case requestPath = "request_path"
        case requestedDisplayName = "requested_display_name"
        case repositoryIdentityAssertion = "repository_identity_assertion"
        case operationID = "operation_id"
        case createdAt = "created_at"
    }
}

struct OperatorProject: Decodable, Sendable, Equatable, Identifiable {
    let projectID: String
    let displayName: String
    let canonicalRoot: String
    let projectGeneration: UInt64
    let lifecycleState: String
    let bindings: [OperatorBinding]
    let memory: OperatorMemoryHealth?
    let continuity: OperatorProjectContinuity?
    let migrationWarnings: [String]
    let resetReceipt: OperatorResetReceipt?
    let pendingTransition: OperatorProjectTransition?

    var id: String { projectID }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case displayName = "display_name"
        case canonicalRoot = "canonical_root"
        case projectGeneration = "project_generation"
        case lifecycleState = "lifecycle_state"
        case bindings, memory, continuity
        case migrationWarnings = "migration_warnings"
        case resetReceipt = "reset_receipt"
        case pendingTransition = "pending_transition"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        displayName = try container.decode(String.self, forKey: .displayName)
        canonicalRoot = try container.decode(String.self, forKey: .canonicalRoot)
        projectGeneration = try container.decode(UInt64.self, forKey: .projectGeneration)
        lifecycleState = try container.decode(String.self, forKey: .lifecycleState)
        bindings = try container.decode([OperatorBinding].self, forKey: .bindings)
        memory = try container.decode(OperatorMemoryHealth.self, forKey: .memory)
        continuity = try container.decode(OperatorProjectContinuity.self, forKey: .continuity)
        migrationWarnings = try container.decode([String].self, forKey: .migrationWarnings)
        resetReceipt = try container.decodeIfPresent(OperatorResetReceipt.self, forKey: .resetReceipt)
        pendingTransition = try container.decodeIfPresent(
            OperatorProjectTransition.self,
            forKey: .pendingTransition
        )
    }
}

struct OperatorProjectTransition: Decodable, Sendable, Equatable {
    let kind: String
    let state: String
    let requestPath: String
    let requestedDisplayName: String?
    let repositoryIdentityAssertion: String?
    let expectedGeneration: UInt64?
    let operationID: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case kind, state
        case requestPath = "request_path"
        case requestedDisplayName = "requested_display_name"
        case repositoryIdentityAssertion = "repository_identity_assertion"
        case expectedGeneration = "expected_generation"
        case operationID = "operation_id"
        case createdAt = "created_at"
    }
}

struct OperatorBinding: Decodable, Sendable, Equatable, Identifiable {
    let bindingID: String
    let ownerKind: String
    let ownerID: String
    let runID: String?
    let active: Bool

    var id: String { bindingID }

    enum CodingKeys: String, CodingKey {
        case bindingID = "binding_id"
        case ownerKind = "owner_kind"
        case ownerID = "owner_id"
        case runID = "run_id"
        case active
    }
}

struct OperatorMemoryHealth: Decodable, Sendable, Equatable {
    let state: String
    let databaseBytes: UInt64?
    let recordCount: Int?
    let lastIntegrityCheck: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case state, detail
        case databaseBytes = "database_bytes"
        case recordCount = "record_count"
        case lastIntegrityCheck = "last_integrity_check"
    }
}

struct OperatorProjectContinuity: Decodable, Sendable, Equatable {
    let state: String
    let latestHandoffID: String?
    let latestHandoffSHA256: String?
    let migrationState: String?

    enum CodingKeys: String, CodingKey {
        case state
        case latestHandoffID = "latest_handoff_id"
        case latestHandoffSHA256 = "latest_handoff_sha256"
        case migrationState = "migration_state"
    }
}

struct OperatorResetReceipt: Decodable, Sendable, Equatable {
    let priorGeneration: UInt64
    let newGeneration: UInt64
    let invalidatedBindingCount: Int
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case priorGeneration = "prior_generation"
        case newGeneration = "new_generation"
        case invalidatedBindingCount = "invalidated_binding_count"
        case completedAt = "completed_at"
    }
}

struct OperatorRelinkReceipt: Decodable, Sendable, Equatable {
    let projectID: String
    let canonicalRoot: String
    let priorGeneration: UInt64
    let newGeneration: UInt64
    let invalidatedBindingCount: Int
    let completedAt: String
    let reconciled: Bool

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case canonicalRoot = "canonical_root"
        case priorGeneration = "prior_generation"
        case newGeneration = "new_generation"
        case invalidatedBindingCount = "invalidated_binding_count"
        case completedAt = "completed_at"
        case reconciled
    }
}

struct OperatorRun: Decodable, Sendable, Equatable, Identifiable {
    let runID: String
    let projectID: String
    let projectGeneration: UInt64
    let assignmentID: String?
    let mission: String
    let state: String
    let continuityMode: String
    let providerID: String?
    let adapterID: String?
    let modelKey: String?
    let providerInstanceID: String?
    let activeSessionID: String?
    let predecessorSessionID: String?
    let activeOperationID: String?
    let continuationPending: Bool
    let leaseOwner: String?
    let workItem: String?
    let lastModelTurnAt: String?
    let lastToolActivityAt: String?
    let completionGates: [String]
    let passedGates: [String]
    let lastErrorCode: String?
    let lastErrorSummary: String?
    let retryAt: String?
    let createdAt: String?
    let updatedAt: String?

    var id: String { runID }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case assignmentID = "assignment_id"
        case mission, state
        case continuityMode = "continuity_mode"
        case providerID = "provider_id"
        case adapterID = "adapter_id"
        case modelKey = "model_key"
        case providerInstanceID = "provider_instance_id"
        case activeSessionID = "active_session_id"
        case predecessorSessionID = "predecessor_session_id"
        case activeOperationID = "active_operation_id"
        case continuationPending = "continuation_pending"
        case leaseOwner = "lease_owner"
        case workItem = "work_item"
        case lastModelTurnAt = "last_model_turn_at"
        case lastToolActivityAt = "last_tool_activity_at"
        case completionGates = "completion_gates"
        case passedGates = "passed_gates"
        case lastErrorCode = "last_error_code"
        case lastErrorSummary = "last_error_summary"
        case retryAt = "retry_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        projectID = try container.decode(String.self, forKey: .projectID)
        projectGeneration = try container.decodeIfPresent(UInt64.self, forKey: .projectGeneration) ?? 0
        assignmentID = try container.decodeIfPresent(String.self, forKey: .assignmentID)
        mission = try container.decodeIfPresent(String.self, forKey: .mission) ?? "Mission unavailable"
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        continuityMode = try container.decodeIfPresent(String.self, forKey: .continuityMode) ?? "unknown"
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        adapterID = try container.decodeIfPresent(String.self, forKey: .adapterID)
        modelKey = try container.decodeIfPresent(String.self, forKey: .modelKey)
        providerInstanceID = try container.decodeIfPresent(String.self, forKey: .providerInstanceID)
        activeSessionID = try container.decodeIfPresent(String.self, forKey: .activeSessionID)
        predecessorSessionID = try container.decodeIfPresent(String.self, forKey: .predecessorSessionID)
        activeOperationID = try container.decodeIfPresent(String.self, forKey: .activeOperationID)
        continuationPending = try container.decodeIfPresent(Bool.self, forKey: .continuationPending) ?? false
        leaseOwner = try container.decodeIfPresent(String.self, forKey: .leaseOwner)
        workItem = try container.decodeIfPresent(String.self, forKey: .workItem)
        lastModelTurnAt = try container.decodeIfPresent(String.self, forKey: .lastModelTurnAt)
        lastToolActivityAt = try container.decodeIfPresent(String.self, forKey: .lastToolActivityAt)
        completionGates = try container.decodeIfPresent([String].self, forKey: .completionGates) ?? []
        passedGates = try container.decodeIfPresent([String].self, forKey: .passedGates) ?? []
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastErrorSummary = try container.decodeIfPresent(String.self, forKey: .lastErrorSummary)
        retryAt = try container.decodeIfPresent(String.self, forKey: .retryAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct OperatorContextBudget: Decodable, Sendable, Equatable {
    let capacityTokens: Int?
    let usedTokens: Int?
    let responseReserveTokens: Int?
    let handoffReserveTokens: Int?
    let recoveryReserveTokens: Int?
    let remainingTokens: Int?
    let source: String?
    let confidence: String?
    let action: String?
    let checkpointThreshold: Int?
    let rolloverThreshold: Int?

    enum CodingKeys: String, CodingKey {
        case capacityTokens = "capacity_tokens"
        case usedTokens = "used_tokens"
        case responseReserveTokens = "response_reserve_tokens"
        case handoffReserveTokens = "handoff_reserve_tokens"
        case recoveryReserveTokens = "recovery_reserve_tokens"
        case remainingTokens = "remaining_tokens"
        case source, confidence, action
        case checkpointThreshold = "checkpoint_threshold"
        case rolloverThreshold = "rollover_threshold"
    }
}

struct OperatorContinuity: Decodable, Sendable, Equatable, Identifiable {
    let operationID: String
    let projectID: String
    let projectGeneration: UInt64
    let runID: String
    let mode: String
    let state: String
    let controlState: String?
    let checkpointID: String?
    let handoffID: String?
    let handoffSHA256: String?
    let predecessorSessionID: String?
    let successorSessionID: String?
    let successorProviderResponseID: String?
    let acknowledgementSHA256: String?
    let attempt: Int
    let continuationIssued: Bool
    let budget: OperatorContextBudget?
    let lastError: String?
    let retryAt: String?
    let updatedAt: String?

    var id: String { operationID }

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runID = "run_id"
        case mode, state, budget, attempt
        case controlState = "control_state"
        case checkpointID = "checkpoint_id"
        case handoffID = "handoff_id"
        case handoffSHA256 = "handoff_sha256"
        case predecessorSessionID = "predecessor_session_id"
        case successorSessionID = "successor_session_id"
        case successorProviderResponseID = "successor_provider_response_id"
        case acknowledgementSHA256 = "acknowledgement_sha256"
        case continuationIssued = "continuation_issued"
        case lastError = "last_error"
        case retryAt = "retry_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decode(String.self, forKey: .operationID)
        projectID = try container.decode(String.self, forKey: .projectID)
        projectGeneration = try container.decodeIfPresent(UInt64.self, forKey: .projectGeneration) ?? 0
        runID = try container.decodeIfPresent(String.self, forKey: .runID) ?? "unavailable"
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "unknown"
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        controlState = try container.decodeIfPresent(String.self, forKey: .controlState)
        checkpointID = try container.decodeIfPresent(String.self, forKey: .checkpointID)
        handoffID = try container.decodeIfPresent(String.self, forKey: .handoffID)
        handoffSHA256 = try container.decodeIfPresent(String.self, forKey: .handoffSHA256)
        predecessorSessionID = try container.decodeIfPresent(String.self, forKey: .predecessorSessionID)
        successorSessionID = try container.decodeIfPresent(String.self, forKey: .successorSessionID)
        successorProviderResponseID = try container.decodeIfPresent(String.self, forKey: .successorProviderResponseID)
        acknowledgementSHA256 = try container.decodeIfPresent(String.self, forKey: .acknowledgementSHA256)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        continuationIssued = try container.decodeIfPresent(Bool.self, forKey: .continuationIssued) ?? false
        budget = try container.decodeIfPresent(OperatorContextBudget.self, forKey: .budget)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        retryAt = try container.decodeIfPresent(String.self, forKey: .retryAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct OperatorRuntimeJob: Decodable, Sendable, Equatable, Identifiable {
    let jobID: String
    let runID: String?
    let projectID: String
    let projectGeneration: UInt64
    let runtimeKind: String
    let state: String
    let canonicalWorkingDirectory: String
    let commandSummary: String
    let timeoutSeconds: Int
    let exitCode: Int?
    let outputArtifactID: String?
    let outputBytes: UInt64
    let errorSummary: String?
    let createdAt: String?
    let completedAt: String?

    var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runtimeKind = "runtime_kind"
        case state
        case canonicalWorkingDirectory = "canonical_working_directory"
        case commandSummary = "command_summary"
        case timeoutSeconds = "timeout_seconds"
        case exitCode = "exit_code"
        case outputArtifactID = "output_artifact_id"
        case outputBytes = "output_bytes"
        case errorSummary = "error_summary"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        projectID = try container.decode(String.self, forKey: .projectID)
        projectGeneration = try container.decodeIfPresent(UInt64.self, forKey: .projectGeneration) ?? 0
        runtimeKind = try container.decodeIfPresent(String.self, forKey: .runtimeKind) ?? "unknown"
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        canonicalWorkingDirectory = try container.decodeIfPresent(
            String.self,
            forKey: .canonicalWorkingDirectory
        ) ?? "Unavailable"
        commandSummary = try container.decodeIfPresent(String.self, forKey: .commandSummary) ?? "Unavailable"
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 0
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        outputArtifactID = try container.decodeIfPresent(String.self, forKey: .outputArtifactID)
        outputBytes = try container.decodeIfPresent(UInt64.self, forKey: .outputBytes) ?? 0
        errorSummary = try container.decodeIfPresent(String.self, forKey: .errorSummary)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    }
}

struct OperatorRuntimeExecutable: Decodable, Sendable, Equatable {
    let available: Bool
    let path: String?
    let version: String?
}

struct OperatorRuntimePolicy: Decodable, Sendable, Equatable {
    let direct: OperatorRuntimeExecutable
    let zsh: OperatorRuntimeExecutable
    let bash: OperatorRuntimeExecutable
    let python: OperatorRuntimeExecutable
    let powershell: OperatorRuntimeExecutable
    let maximumConcurrentJobs: Int
    let defaultTimeoutSeconds: Int
    let maximumInlineOutputBytes: Int
    let maximumArtifactBytesPerJob: Int
    let networkPolicy: String
    let shellPolicyMigrationState: String

    enum CodingKeys: String, CodingKey {
        case direct, zsh, bash, python, powershell
        case maximumConcurrentJobs = "maximum_concurrent_jobs"
        case defaultTimeoutSeconds = "default_timeout_seconds"
        case maximumInlineOutputBytes = "maximum_inline_output_bytes"
        case maximumArtifactBytesPerJob = "maximum_artifact_bytes_per_job"
        case networkPolicy = "network_policy"
        case shellPolicyMigrationState = "shell_policy_migration_state"
    }
}

enum OperatorProviderProbeMode: String, Encodable, Sendable {
    case connection
    case contract
}

struct OperatorProvider: Decodable, Sendable, Equatable {
    let adapterID: String?
    let providerID: String?
    let health: String
    let endpoint: String?
    let loopback: Bool?
    let tls: Bool?
    let authenticationEnabled: Bool?
    let credentialConfigured: Bool?
    let apiMode: String?
    let modelKey: String?
    let instanceID: String?
    let activeContextLength: Int?
    let maximumContextLength: Int?
    let toolUseCapable: Bool?
    let lifecycleManagementEnabled: Bool?
    let idleTTLSeconds: Int?
    let contractFingerprint: String?
    let lastProbeMode: String?
    let probeResultStorage: String?
    let lastProbeAt: String?
    let lastProbeError: String?

    enum CodingKeys: String, CodingKey {
        case adapterID = "adapter_id"
        case providerID = "provider_id"
        case health, endpoint, loopback, tls
        case authenticationEnabled = "authentication_enabled"
        case credentialConfigured = "credential_configured"
        case apiMode = "api_mode"
        case modelKey = "model_key"
        case instanceID = "instance_id"
        case activeContextLength = "active_context_length"
        case maximumContextLength = "maximum_context_length"
        case toolUseCapable = "tool_use_capable"
        case lifecycleManagementEnabled = "lifecycle_management_enabled"
        case idleTTLSeconds = "idle_ttl_seconds"
        case contractFingerprint = "contract_fingerprint"
        case lastProbeMode = "last_probe_mode"
        case probeResultStorage = "probe_result_storage"
        case lastProbeAt = "last_probe_at"
        case lastProbeError = "last_probe_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adapterID = try container.decodeIfPresent(String.self, forKey: .adapterID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        health = try container.decodeIfPresent(String.self, forKey: .health) ?? "unavailable"
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        loopback = try container.decodeIfPresent(Bool.self, forKey: .loopback)
        tls = try container.decodeIfPresent(Bool.self, forKey: .tls)
        authenticationEnabled = try container.decodeIfPresent(Bool.self, forKey: .authenticationEnabled)
        credentialConfigured = try container.decodeIfPresent(Bool.self, forKey: .credentialConfigured)
        apiMode = try container.decodeIfPresent(String.self, forKey: .apiMode)
        modelKey = try container.decodeIfPresent(String.self, forKey: .modelKey)
        instanceID = try container.decodeIfPresent(String.self, forKey: .instanceID)
        activeContextLength = try container.decodeIfPresent(Int.self, forKey: .activeContextLength)
        maximumContextLength = try container.decodeIfPresent(Int.self, forKey: .maximumContextLength)
        toolUseCapable = try container.decodeIfPresent(Bool.self, forKey: .toolUseCapable)
        lifecycleManagementEnabled = try container.decodeIfPresent(Bool.self, forKey: .lifecycleManagementEnabled)
        idleTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .idleTTLSeconds)
        contractFingerprint = try container.decodeIfPresent(String.self, forKey: .contractFingerprint)
        lastProbeMode = try container.decodeIfPresent(String.self, forKey: .lastProbeMode)
        probeResultStorage = try container.decodeIfPresent(String.self, forKey: .probeResultStorage)
        lastProbeAt = try container.decodeIfPresent(String.self, forKey: .lastProbeAt)
        lastProbeError = try container.decodeIfPresent(String.self, forKey: .lastProbeError)
    }
}

struct OperatorEvent: Decodable, Sendable, Equatable, Identifiable {
    let eventID: String
    let timestamp: String
    let kind: String
    let summary: String
    let severity: String?
    let projectID: String?
    let runID: String?
    let operationID: String?
    let jobID: String?
    let providerRequestID: String?
    let artifactID: String?

    var id: String { eventID }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case timestamp, kind, summary, severity
        case projectID = "project_id"
        case runID = "run_id"
        case operationID = "operation_id"
        case jobID = "job_id"
        case providerRequestID = "provider_request_id"
        case artifactID = "artifact_id"
    }
}

struct OperatorAutonomySummary: Decodable, Sendable, Equatable {
    let started: Bool
    let activeRunIDs: [String]
    let deferredRunIDs: [String]

    enum CodingKeys: String, CodingKey {
        case started
        case activeRunIDs = "active_run_ids"
        case deferredRunIDs = "deferred_run_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        started = try container.decodeIfPresent(Bool.self, forKey: .started) ?? false
        activeRunIDs = try container.decodeIfPresent([String].self, forKey: .activeRunIDs) ?? []
        deferredRunIDs = try container.decodeIfPresent([String].self, forKey: .deferredRunIDs) ?? []
    }
}

enum OperatorRunControlAction: String, Encodable, Sendable, Equatable, CaseIterable {
    case pause, resume, cancel, retry
    case checkpoint, rollover
}

struct OperatorRunStartRequest: Encodable, Sendable, Equatable {
    let runID: String
    let projectID: String
    let projectGeneration: UInt64
    let assignmentID: String?
    let mission: String
    let providerID: String
    let adapterID: String
    let modelKey: String
    let allowedTools: [String]
    let completionGates: [String]
    let networkAllowed: Bool
    let maximumInlineOutputBytes: Int

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case assignmentID = "assignment_id"
        case mission
        case providerID = "provider_id"
        case adapterID = "adapter_id"
        case modelKey = "model_key"
        case allowedTools = "allowed_tools"
        case completionGates = "completion_gates"
        case networkAllowed = "network_allowed"
        case maximumInlineOutputBytes = "maximum_inline_output_bytes"
    }
}

struct OperatorProjectRegistrationRequest: Encodable, Sendable, Equatable {
    let path: String
    let displayName: String?
    let repositoryIdentity: String?

    enum CodingKeys: String, CodingKey {
        case path
        case displayName = "display_name"
        case repositoryIdentity = "repository_identity"
    }
}

struct OperatorPendingProjectRegistration: Sendable, Equatable {
    let request: OperatorProjectRegistrationRequest
    let projectID: String?
    let code: String
    let message: String
}

enum OperatorProjectRegistrationOutcome: Sendable, Equatable {
    case committed(project: OperatorProject, reconciled: Bool)
    case reconciliationRequired(OperatorPendingProjectRegistration)
}
