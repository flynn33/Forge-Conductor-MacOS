// AutonomyModels.swift
// Defines durable run, lease, provider-intent, tool-intent, and completion contracts.

import Foundation

public enum AutonomousRunState: String, Codable, Sendable, CaseIterable {
    case created
    case validating
    case ready
    case starting
    case running
    case checkpointing
    case rollingOver = "rolling_over"
    case recovering
    case validatingCompletion = "validating_completion"
    case completed
    case waitingProvider = "waiting_provider"
    case waitingResource = "waiting_resource"
    case retryWait = "retry_wait"
    case paused
    case blockedConfiguration = "blocked_configuration"
    case failedRecoverable = "failed_recoverable"
    case cancelRequested = "cancel_requested"
    case cancelled
    case failedTerminal = "failed_terminal"

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failedTerminal:
            true
        default:
            false
        }
    }

    public var isExecutable: Bool {
        switch self {
        case .created, .validating, .ready, .starting, .running, .checkpointing,
             .rollingOver, .recovering, .validatingCompletion, .waitingProvider,
             .waitingResource, .retryWait, .failedRecoverable, .cancelRequested:
            true
        case .paused, .blockedConfiguration, .completed, .cancelled, .failedTerminal:
            false
        }
    }
}

public enum AutonomyResourceProfile: String, Codable, Sendable, CaseIterable {
    case constrained
    case standard
    case expanded
    case automatic
}

public struct AutonomousRunSpecification: Codable, Sendable, Equatable {
    public let allowedTools: [String]
    public let completionGates: [String]
    public let resourceProfile: AutonomyResourceProfile
    public var work: AutonomousRunWork

    public init(
        allowedTools: [String],
        completionGates: [String],
        resourceProfile: AutonomyResourceProfile = .automatic,
        work: AutonomousRunWork = .init()
    ) {
        self.allowedTools = allowedTools
        self.completionGates = completionGates
        self.resourceProfile = resourceProfile
        self.work = work
    }

    private enum CodingKeys: String, CodingKey {
        case allowedTools = "allowed_tools"
        case completionGates = "completion_gates"
        case resourceProfile = "resource_profile"
        case work
    }
}

public struct AutonomousRunWork: Codable, Sendable, Equatable {
    public var currentPhase: String?
    public var workItem: String?
    public var nextAction: String?
    public var pendingIntent: RunSideEffectIntent?
    public var evidenceReferences: [String]
    public var metadata: [String: String]

    public init(
        currentPhase: String? = nil,
        workItem: String? = nil,
        nextAction: String? = nil,
        pendingIntent: RunSideEffectIntent? = nil,
        evidenceReferences: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.currentPhase = currentPhase
        self.workItem = workItem
        self.nextAction = nextAction
        self.pendingIntent = pendingIntent
        self.evidenceReferences = evidenceReferences
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case currentPhase = "current_phase"
        case workItem = "work_item"
        case nextAction = "next_action"
        case pendingIntent = "pending_intent"
        case evidenceReferences = "evidence_references"
        case metadata
    }
}

public enum RunSideEffectKind: String, Codable, Sendable, CaseIterable {
    case providerTurn = "provider_turn"
    case toolInvocation = "tool_invocation"
    case continuity
    case runtimeJob = "runtime_job"
    case completionValidation = "completion_validation"
}

public struct RunSideEffectIntent: Codable, Sendable, Equatable {
    public let intentID: UUID
    public let kind: RunSideEffectKind
    public let idempotencyKey: String
    public let payloadSHA256: String
    public let summary: String

    public init(
        intentID: UUID = UUID(),
        kind: RunSideEffectKind,
        idempotencyKey: String,
        payloadSHA256: String,
        summary: String
    ) {
        self.intentID = intentID
        self.kind = kind
        self.idempotencyKey = idempotencyKey
        self.payloadSHA256 = payloadSHA256
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case intentID = "intent_id"
        case kind
        case idempotencyKey = "idempotency_key"
        case payloadSHA256 = "payload_sha256"
        case summary
    }
}

public struct AutonomousRunRequest: Sendable, Equatable {
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let assignmentID: String?
    public let mission: String
    public let continuityMode: ContinuityMode
    public let providerID: String
    public let adapterID: String
    public let modelKey: String
    public let specification: AutonomousRunSpecification
    public let authorizationScope: ToolAuthorizationScope

    public init(
        runID: RunID = RunID(),
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        assignmentID: String? = nil,
        mission: String,
        continuityMode: ContinuityMode = .managedAutonomous,
        providerID: String,
        adapterID: String? = nil,
        modelKey: String,
        specification: AutonomousRunSpecification,
        authorizationScope: ToolAuthorizationScope
    ) {
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.assignmentID = assignmentID
        self.mission = mission
        self.continuityMode = continuityMode
        self.providerID = providerID
        self.adapterID = adapterID ?? providerID
        self.modelKey = modelKey
        var persistedSpecification = specification
        persistedSpecification.work.metadata["adapter_id"] = self.adapterID
        self.specification = persistedSpecification
        self.authorizationScope = authorizationScope
    }
}

public struct AutonomousRunRecord: Codable, Sendable, Equatable {
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let assignmentID: String?
    public let mission: String
    public let state: AutonomousRunState
    public let continuityMode: ContinuityMode
    public let providerID: String?
    public let modelKey: String?
    public let activeSessionID: String?
    public let activeOperationID: UUID?
    public let specification: AutonomousRunSpecification
    public let completionRequestJSON: String?
    public let lastErrorCode: String?
    public let lastErrorSummary: String?
    public let retryAt: String?
    public let continuationPending: Bool
    public let revision: UInt64
    public let createdAt: String
    public let updatedAt: String

    /// The statically registered adapter identity is persisted inside the bounded
    /// run-work envelope so existing control-plane databases remain migration-safe.
    /// `providerID` names the service (for example, `lmstudio`); this value names
    /// the exact plugin registration used to create and recover sessions.
    public var adapterID: String? {
        specification.work.metadata["adapter_id"]
    }
}

public struct RunLeasePolicy: Sendable, Equatable {
    public let duration: TimeInterval
    public let renewalInterval: TimeInterval
    public let maximumDuration: TimeInterval

    public init(
        duration: TimeInterval = 30,
        renewalInterval: TimeInterval = 10,
        maximumDuration: TimeInterval = 300
    ) {
        self.duration = duration
        self.renewalInterval = renewalInterval
        self.maximumDuration = maximumDuration
    }
}

public struct RunLease: Codable, Sendable, Equatable {
    public let runID: RunID
    public let ownerID: String
    public let epoch: UInt64
    public let acquiredAt: String
    public let renewedAt: String
    public let expiresAt: String

    public var expirationDate: Date? { ISO8601.date(from: expiresAt) }
}

public struct AutonomousRunTransition: Sendable, Equatable {
    public let expectedState: AutonomousRunState
    public let expectedRevision: UInt64
    public let nextState: AutonomousRunState
    public let eventType: String
    public let eventSummary: String
    public let work: AutonomousRunWork?
    public let activeSessionID: String?
    public let activeOperationID: UUID?
    public let completionRequestJSON: String?
    public let errorCode: String?
    public let errorSummary: String?
    public let retryAt: String?

    public init(
        expectedState: AutonomousRunState,
        expectedRevision: UInt64,
        nextState: AutonomousRunState,
        eventType: String,
        eventSummary: String,
        work: AutonomousRunWork? = nil,
        activeSessionID: String? = nil,
        activeOperationID: UUID? = nil,
        completionRequestJSON: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        retryAt: String? = nil
    ) {
        self.expectedState = expectedState
        self.expectedRevision = expectedRevision
        self.nextState = nextState
        self.eventType = eventType
        self.eventSummary = eventSummary
        self.work = work
        self.activeSessionID = activeSessionID
        self.activeOperationID = activeOperationID
        self.completionRequestJSON = completionRequestJSON
        self.errorCode = errorCode
        self.errorSummary = errorSummary
        self.retryAt = retryAt
    }
}

public enum ProviderSessionStatus: String, Codable, Sendable, CaseIterable {
    case candidate
    case active
    case fencing
    case fenced
    case sealed
    case quarantinedDuplicate = "quarantined_duplicate"
    case cancelled
    case failed
    case legacySynthetic = "legacy_synthetic"
}

public struct ProviderSessionIntent: Sendable, Equatable {
    public let sessionID: String
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let providerID: String
    public let adapterID: String
    public let modelKey: String
    public let providerResponseID: String?
    public let predecessorSessionID: String?
    public let handoffID: UUID?
    public let operationID: UUID?
    public let idempotencyKey: String
    public let bootstrapNonceSHA256: String?
    public let handoffSHA256: String?
    public let status: ProviderSessionStatus
    public let accepted: Bool
    public let contextCapacity: Int?

    public init(
        sessionID: String,
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        providerID: String,
        adapterID: String,
        modelKey: String,
        providerResponseID: String? = nil,
        predecessorSessionID: String? = nil,
        handoffID: UUID? = nil,
        operationID: UUID? = nil,
        idempotencyKey: String,
        bootstrapNonceSHA256: String? = nil,
        handoffSHA256: String? = nil,
        status: ProviderSessionStatus = .active,
        accepted: Bool = true,
        contextCapacity: Int? = nil
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.providerID = providerID
        self.adapterID = adapterID
        self.modelKey = modelKey
        self.providerResponseID = providerResponseID
        self.predecessorSessionID = predecessorSessionID
        self.handoffID = handoffID
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.bootstrapNonceSHA256 = bootstrapNonceSHA256
        self.handoffSHA256 = handoffSHA256
        self.status = status
        self.accepted = accepted
        self.contextCapacity = contextCapacity
    }
}

/// Durable provider-session identity including the exact bootstrap receipt provenance.
/// Nonce material is never stored directly in the control plane; only its SHA-256 is kept.
public struct ProviderSessionRecord: Codable, Sendable, Equatable {
    public let sessionID: String
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let providerID: String
    public let adapterID: String
    public let modelKey: String
    public let providerResponseID: String?
    public let predecessorSessionID: String?
    public let handoffID: UUID?
    public let operationID: UUID?
    public let idempotencyKey: String
    public let bootstrapNonceSHA256: String?
    public let handoffSHA256: String?
    public let status: ProviderSessionStatus
    public let accepted: Bool
    public let contextCapacity: Int?
    public let createdAt: String
    public let updatedAt: String
}

/// The complete control-plane commit request after a V2 bootstrap receipt has been
/// validated against the project-local handoff. Applying it is one SQLite transaction.
public struct ContinuitySuccessorAcceptance: Sendable, Equatable {
    public let operationID: UUID
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let predecessorSessionID: String
    public let candidateSessionID: String
    public let handoffID: UUID
    public let handoffSHA256: String
    public let bootstrapNonceSHA256: String
    public let automaticContinuationInputSHA256: String
    public let automaticContinuationIdempotencyKey: String

    public init(
        operationID: UUID,
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        predecessorSessionID: String,
        candidateSessionID: String,
        handoffID: UUID,
        handoffSHA256: String,
        bootstrapNonceSHA256: String,
        automaticContinuationInputSHA256: String,
        automaticContinuationIdempotencyKey: String
    ) {
        self.operationID = operationID
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.predecessorSessionID = predecessorSessionID
        self.candidateSessionID = candidateSessionID
        self.handoffID = handoffID
        self.handoffSHA256 = handoffSHA256
        self.bootstrapNonceSHA256 = bootstrapNonceSHA256
        self.automaticContinuationInputSHA256 = automaticContinuationInputSHA256
        self.automaticContinuationIdempotencyKey = automaticContinuationIdempotencyKey
    }
}

public struct ContinuitySuccessorAcceptanceReceipt: Sendable, Equatable {
    public let winner: ProviderSessionRecord
    public let automaticContinuation: ProviderTurnRecord
    public let quarantinedSessionIDs: [String]

    public init(
        winner: ProviderSessionRecord,
        automaticContinuation: ProviderTurnRecord,
        quarantinedSessionIDs: [String]
    ) {
        self.winner = winner
        self.automaticContinuation = automaticContinuation
        self.quarantinedSessionIDs = quarantinedSessionIDs
    }
}

public enum ProviderTurnKind: String, Codable, Sendable, CaseIterable {
    case initialRoot = "initial_root"
    case normalContinuation = "normal_continuation"
    case bootstrap
    case toolContinuation = "tool_continuation"
    case automaticContinuation = "automatic_continuation"
}

public enum ProviderTurnState: String, Codable, Sendable, CaseIterable {
    case intent
    case submitted
    case streaming
    case completed
    case ambiguous
    case retryWait = "retry_wait"
    case failed
    case cancelled
}

public struct ProviderTurnIntent: Sendable, Equatable {
    public let turnID: UUID
    public let runID: RunID
    public let sessionID: String
    public let operationID: UUID?
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let kind: ProviderTurnKind
    public let idempotencyKey: String
    public let previousResponseID: String?
    public let inputSHA256: String
    public let toolSchemaSHA256: String?

    public init(
        turnID: UUID = UUID(),
        runID: RunID,
        sessionID: String,
        operationID: UUID? = nil,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        kind: ProviderTurnKind,
        idempotencyKey: String,
        previousResponseID: String? = nil,
        inputSHA256: String,
        toolSchemaSHA256: String? = nil
    ) {
        self.turnID = turnID
        self.runID = runID
        self.sessionID = sessionID
        self.operationID = operationID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.kind = kind
        self.idempotencyKey = idempotencyKey
        self.previousResponseID = previousResponseID
        self.inputSHA256 = inputSHA256
        self.toolSchemaSHA256 = toolSchemaSHA256
    }
}

public struct ProviderTurnRecord: Codable, Sendable, Equatable {
    public let intent: ProviderTurnIntentRecord
    public let state: ProviderTurnState
    public let providerRequestID: String?
    public let providerResponseID: String?
    public let usageJSON: String?
    public let attempt: Int
    public let retryAt: String?
    public let lastErrorCode: String?
    public let lastErrorSummary: String?
    public let createdAt: String
    public let updatedAt: String
}

public struct ProviderTurnIntentRecord: Codable, Sendable, Equatable {
    public let turnID: UUID
    public let runID: RunID
    public let sessionID: String
    public let operationID: UUID?
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let kind: ProviderTurnKind
    public let idempotencyKey: String
    public let previousResponseID: String?
    public let inputSHA256: String
    public let toolSchemaSHA256: String?
}

public enum ToolReplayClass: String, Codable, Sendable, CaseIterable {
    case readOnly = "read_only"
    case idempotent
    case reconciled
    case nonReplayable = "non_replayable"

    public var permitsAutomaticReplay: Bool {
        self == .readOnly || self == .idempotent
    }
}

public enum ToolInvocationState: String, Codable, Sendable, CaseIterable {
    case intent
    case executing
    case completed
    case ambiguous
    case failed
    case cancelled
    case quarantinedStale = "quarantined_stale"
}

public struct ToolInvocationIntent: Sendable, Equatable {
    public let invocationID: UUID
    public let turnID: UUID
    public let runID: RunID
    public let sessionID: String
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let providerCallID: String
    public let toolName: String
    public let replayClass: ToolReplayClass
    public let idempotencyKey: String?
    public let argumentsSHA256: String
    public let reconciliationDescriptor: String?

    public init(
        invocationID: UUID = UUID(),
        turnID: UUID,
        runID: RunID,
        sessionID: String,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        providerCallID: String,
        toolName: String,
        replayClass: ToolReplayClass,
        idempotencyKey: String?,
        argumentsSHA256: String,
        reconciliationDescriptor: String? = nil
    ) {
        self.invocationID = invocationID
        self.turnID = turnID
        self.runID = runID
        self.sessionID = sessionID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.providerCallID = providerCallID
        self.toolName = toolName
        self.replayClass = replayClass
        self.idempotencyKey = idempotencyKey
        self.argumentsSHA256 = argumentsSHA256
        self.reconciliationDescriptor = reconciliationDescriptor
    }
}

public struct ToolInvocationRecord: Codable, Sendable, Equatable {
    public let invocationID: UUID
    public let turnID: UUID
    public let runID: RunID
    public let sessionID: String
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let providerCallID: String
    public let toolName: String
    public let replayClass: ToolReplayClass
    public let idempotencyKey: String?
    public let argumentsSHA256: String
    public let reconciliationDescriptor: String?
    public let state: ToolInvocationState
    public let resultSHA256: String?
    public let resultSummary: String?
    public let lastErrorCode: String?
    public let lastErrorSummary: String?
    public let createdAt: String
    public let updatedAt: String
}

public struct CompletionGateResult: Codable, Sendable, Equatable {
    public let gate: String
    public let passed: Bool
    public let summary: String
    public let evidenceReferences: [String]

    public init(
        gate: String,
        passed: Bool,
        summary: String,
        evidenceReferences: [String] = []
    ) {
        self.gate = gate
        self.passed = passed
        self.summary = summary
        self.evidenceReferences = evidenceReferences
    }

    private enum CodingKeys: String, CodingKey {
        case gate, passed, summary
        case evidenceReferences = "evidence_references"
    }
}

public struct CompletionValidationReceipt: Codable, Sendable, Equatable {
    public let runID: RunID
    public let expectedRevision: UInt64
    public let results: [CompletionGateResult]
    public let passed: Bool
    public let validatedAt: String
    public let proofSHA256: String

    public init(
        runID: RunID,
        expectedRevision: UInt64,
        results: [CompletionGateResult],
        validatedAt: String,
        proofSHA256: String
    ) {
        self.runID = runID
        self.expectedRevision = expectedRevision
        self.results = results
        self.passed = !results.isEmpty && results.allSatisfy(\.passed)
        self.validatedAt = validatedAt
        self.proofSHA256 = proofSHA256
    }

    public static func make(
        runID: RunID,
        expectedRevision: UInt64,
        results: [CompletionGateResult],
        validatedAt: String
    ) throws -> CompletionValidationReceipt {
        let payload = CompletionProofPayload(
            runID: runID,
            expectedRevision: expectedRevision,
            results: results,
            passed: !results.isEmpty && results.allSatisfy(\.passed),
            validatedAt: validatedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let proof = JSONSupport.sha256Hex(try encoder.encode(payload))
        return CompletionValidationReceipt(
            runID: runID,
            expectedRevision: expectedRevision,
            results: results,
            validatedAt: validatedAt,
            proofSHA256: proof
        )
    }

    public func hasValidProof() -> Bool {
        guard let rebuilt = try? Self.make(
            runID: runID,
            expectedRevision: expectedRevision,
            results: results,
            validatedAt: validatedAt
        ) else { return false }
        return rebuilt.passed == passed && rebuilt.proofSHA256 == proofSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case expectedRevision = "expected_revision"
        case results, passed
        case validatedAt = "validated_at"
        case proofSHA256 = "proof_sha256"
    }
}

private struct CompletionProofPayload: Codable {
    let runID: RunID
    let expectedRevision: UInt64
    let results: [CompletionGateResult]
    let passed: Bool
    let validatedAt: String

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case expectedRevision = "expected_revision"
        case results, passed
        case validatedAt = "validated_at"
    }
}

public struct AutonomyEvent: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let eventID: UUID
    public let runID: RunID?
    public let projectID: ProjectID?
    public let eventType: String
    public let severity: AutonomyEventSeverity
    public let summary: String
    public let metadataJSON: String
    public let previousEventSHA256: String?
    public let eventSHA256: String
    public let createdAt: String
}

public enum AutonomyEventSeverity: String, Codable, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
    case critical
}

public struct AutonomyStartupReport: Sendable, Equatable {
    public let releasedExpiredLeases: Int
    public let discoveredRuns: Int
    public let activatedRuns: [RunID]
    public let deferredRuns: [RunID]
    public let staleGenerationRuns: [RunID]
}

public enum AutonomyError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case invalidToolConfiguration([String])
    case runNotFound(RunID)
    case runConflict(RunID)
    case invalidTransition(AutonomousRunState, AutonomousRunState)
    case transitionConflict
    case leaseConflict(ownerID: String, epoch: UInt64)
    case leaseExpired
    case leaseRequired
    case staleLease
    case completionValidationRequired
    case completionValidationFailed
    case replayClassificationRequired(String)
    case replayBlocked(ToolReplayClass)
    case intentConflict
    case providerSessionNotFound(String)
    case providerTurnNotFound(UUID)
    case toolInvocationNotFound(UUID)
    case resultTooLarge
    case shutdown

    public var code: String {
        switch self {
        case .invalidRequest: "autonomy_invalid_request"
        case .invalidToolConfiguration: "autonomy_tool_configuration_invalid"
        case .runNotFound: "autonomous_run_not_found"
        case .runConflict: "autonomous_run_conflict"
        case .invalidTransition: "autonomous_run_invalid_transition"
        case .transitionConflict: "autonomous_run_transition_conflict"
        case .leaseConflict: "autonomous_run_lease_conflict"
        case .leaseExpired: "autonomous_run_lease_expired"
        case .leaseRequired: "autonomous_run_lease_required"
        case .staleLease: "autonomous_run_lease_stale"
        case .completionValidationRequired: "completion_validation_required"
        case .completionValidationFailed: "completion_validation_failed"
        case .replayClassificationRequired: "tool_replay_classification_required"
        case .replayBlocked: "tool_replay_blocked"
        case .intentConflict: "side_effect_intent_conflict"
        case .providerSessionNotFound: "provider_session_not_found"
        case .providerTurnNotFound: "provider_turn_not_found"
        case .toolInvocationNotFound: "tool_invocation_not_found"
        case .resultTooLarge: "tool_result_too_large"
        case .shutdown: "autonomy_shutdown"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): reason
        case .invalidToolConfiguration(let tools):
            "Allowed tools are not registered in this build: \(Self.summarizedToolNames(tools))"
        case .runNotFound(let runID): "Autonomous run not found: \(runID)"
        case .runConflict(let runID): "Autonomous run identity conflicts with its durable record: \(runID)"
        case .invalidTransition(let from, let to): "Invalid autonomous run transition: \(from.rawValue) -> \(to.rawValue)"
        case .transitionConflict: "Autonomous run state or revision changed before commit"
        case .leaseConflict(let ownerID, let epoch): "Run is leased by \(ownerID) at epoch \(epoch)"
        case .leaseExpired: "Run lease expired"
        case .leaseRequired: "A current run lease is required"
        case .staleLease: "Run lease owner or epoch is stale"
        case .completionValidationRequired: "A deterministic completion receipt is required"
        case .completionValidationFailed: "One or more deterministic completion gates failed"
        case .replayClassificationRequired(let tool): "Tool replay classification is required for \(tool)"
        case .replayBlocked(let classification): "Automatic replay is blocked for \(classification.rawValue)"
        case .intentConflict: "Side-effect identity conflicts with its durable intent"
        case .providerSessionNotFound(let sessionID): "Provider session not found: \(sessionID)"
        case .providerTurnNotFound(let turnID): "Provider turn not found: \(turnID.uuidString.lowercased())"
        case .toolInvocationNotFound(let invocationID): "Tool invocation not found: \(invocationID.uuidString.lowercased())"
        case .resultTooLarge: "Tool result exceeds the durable inline result bound"
        case .shutdown: "Autonomy supervisor is shutting down"
        }
    }

    private static func summarizedToolNames(_ tools: [String]) -> String {
        let displayed = tools.prefix(8).joined(separator: ", ")
        let remaining = tools.count - min(tools.count, 8)
        return remaining > 0 ? "\(displayed), and \(remaining) more" : displayed
    }
}
