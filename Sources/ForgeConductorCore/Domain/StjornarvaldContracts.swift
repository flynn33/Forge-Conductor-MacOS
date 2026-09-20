// StjornarvaldContracts.swift
// What: Defines Development Policy identities, observations, violations, and ports.
// How: Small Sendable value types cross the engine, persistence, and reporting boundaries.
// Why: Policy interpretation must stay typed, additive, and unable to control development.

import Foundation

public struct PolicySourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct PolicyRuleID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct PolicyViolationID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct PolicySourceRevisionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct PolicyArtifactID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct PolicySegmentID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public enum PolicySourceOrigin: String, Codable, Sendable {
    case builtInRavenForge = "built_in_raven_forge"
    case userSelected = "user_selected"
}

public enum PolicySourceRootKind: String, Codable, Sendable {
    case regularFile = "regular_file"
    case directory, symbolicLink = "symbolic_link", socket, fifo, characterDevice = "character_device"
    case blockDevice = "block_device"
    case unavailable, unknown
}

public enum PolicySourceInterpretationState: String, Codable, Sendable {
    case accepted, cataloging, indexed
    case partiallyIndexed = "partially_indexed"
    case refreshPending = "refresh_pending"
    case sourceUnavailable = "source_unavailable"
    case removedByUser = "removed_by_user"
}

public struct DevelopmentPolicySource: Codable, Sendable, Equatable, Identifiable {
    public let id: PolicySourceID
    public let origin: PolicySourceOrigin
    public let displayName: String
    public let selectedPath: String
    public let standardizedPath: String
    public let rootKind: PolicySourceRootKind
    public let bookmarkSHA256: String?
    public let active: Bool
    public let interpretationState: PolicySourceInterpretationState
    public let addedAt: Date
    public let latestRevisionID: PolicySourceRevisionID?
    public let lastIndexCursor: String?
    public let latestObservation: String?

    public init(
        id: PolicySourceID = PolicySourceID(),
        origin: PolicySourceOrigin = .userSelected,
        displayName: String,
        selectedPath: String,
        standardizedPath: String? = nil,
        rootKind: PolicySourceRootKind = .unknown,
        bookmarkSHA256: String? = nil,
        active: Bool = true,
        interpretationState: PolicySourceInterpretationState = .accepted,
        addedAt: Date = Date(),
        latestRevisionID: PolicySourceRevisionID? = nil,
        lastIndexCursor: String? = nil,
        latestObservation: String? = nil
    ) {
        self.id = id
        self.origin = origin
        self.displayName = displayName
        self.selectedPath = selectedPath
        self.standardizedPath = standardizedPath ?? selectedPath
        self.rootKind = rootKind
        self.bookmarkSHA256 = bookmarkSHA256
        self.active = active
        self.interpretationState = interpretationState
        self.addedAt = addedAt
        self.latestRevisionID = latestRevisionID
        self.lastIndexCursor = lastIndexCursor
        self.latestObservation = latestObservation
    }
}

public enum PolicyArtifactKind: String, Codable, Sendable {
    case regularFile = "regular_file"
    case directory, package, bundle, archive, text, structuredText = "structured_text"
    case richDocument = "rich_document"
    case pdf, image, media, executable, script, unknownBinary = "unknown_binary"
    case symbolicLink = "symbolic_link"
    case socket, fifo, characterDevice = "character_device", blockDevice = "block_device"
    case unavailable, unknown
}

public enum PolicyArtifactInterpretationState: String, Codable, Sendable {
    case cataloging, indexed, partiallyIndexed = "partially_indexed"
    case metadataOnly = "metadata_only"
    case encryptedContent = "encrypted_content"
    case extractionDeferred = "extraction_deferred"
    case sourceUnavailable = "source_unavailable"
    case sourceChanged = "source_changed"
    case strategyError = "strategy_error"
}

public struct PolicySourceRevision: Codable, Sendable, Equatable, Identifiable {
    public let id: PolicySourceRevisionID
    public let sourceID: PolicySourceID
    public let observedAt: Date
    public let priorRevisionID: PolicySourceRevisionID?
    public let repositoryURL: String?
    public let gitCommit: String?
    public let gitBranch: String?
    public let gitDirty: Bool?
    public let manifestSHA256: String?
    public let metadata: [String: String]
}

public struct PolicyArtifact: Codable, Sendable, Equatable, Identifiable {
    public let id: PolicyArtifactID
    public let revisionID: PolicySourceRevisionID
    public let relativePath: String
    public let kind: PolicyArtifactKind
    public let byteCount: Int64?
    public let contentSHA256: String?
    public let metadata: [String: String]
    public let interpretationState: PolicyArtifactInterpretationState
    public let lastCursor: String?
}

public struct PolicySegment: Codable, Sendable, Equatable, Identifiable {
    public let id: PolicySegmentID
    public let artifactID: PolicyArtifactID
    public let ordinal: Int
    public let locator: String
    public let extractionMethod: String
    public let extractionVersion: String
    public let content: String
    public let contentSHA256: String
    public let confidence: Double
}

public struct PolicySourceIndexProgress: Codable, Sendable, Equatable {
    public let sourceID: PolicySourceID
    public let revisionID: PolicySourceRevisionID?
    public let interpretationState: PolicySourceInterpretationState
    public let pendingWorkCount: Int
    public let completedWorkCount: Int
    public let artifactCount: Int
    public let segmentCount: Int
    public let cursor: String?
    public let observation: String?
}

public struct PolicySourceReference: Codable, Sendable, Equatable {
    public let sourceID: PolicySourceID
    public let revision: String
    public let path: String
    public let locator: String

    public init(sourceID: PolicySourceID, revision: String, path: String, locator: String) {
        self.sourceID = sourceID
        self.revision = revision
        self.path = path
        self.locator = locator
    }
}

public struct GoverningPolicyIdentity: Codable, Sendable, Equatable {
    public let bindingID: String
    public let authority: String
    public let repositoryURL: String
    public let version: String
    public let revision: String
    public let sourceID: PolicySourceID

    public init(
        bindingID: String,
        authority: String,
        repositoryURL: String,
        version: String,
        revision: String,
        sourceID: PolicySourceID
    ) {
        self.bindingID = bindingID
        self.authority = authority
        self.repositoryURL = repositoryURL
        self.version = version
        self.revision = revision
        self.sourceID = sourceID
    }
}

public enum PolicyRuleInterpretationKind: String, Codable, Sendable {
    case explicitRule = "explicit_rule"
    case inferredRule = "inferred_rule"
    case workflow
    case preference
    case example
    case historicalContext = "historical_context"
    case projectDecision = "project_decision"
    case ambiguityRecord = "ambiguity_record"
    case metadataOnlyContext = "metadata_only_context"
}

public struct PolicyRuleDetails: Codable, Sendable, Equatable {
    public let title: String
    public let interpretationKind: PolicyRuleInterpretationKind
    public let interpretationNotes: [String]
    public let evidencePatterns: [String]
    public let suggestedCorrection: String
    public let detectorIDs: [String]
    public let limitations: [String]

    public init(
        title: String,
        interpretationKind: PolicyRuleInterpretationKind,
        interpretationNotes: [String] = [],
        evidencePatterns: [String] = [],
        suggestedCorrection: String,
        detectorIDs: [String] = [],
        limitations: [String] = []
    ) {
        self.title = title
        self.interpretationKind = interpretationKind
        self.interpretationNotes = interpretationNotes
        self.evidencePatterns = evidencePatterns
        self.suggestedCorrection = suggestedCorrection
        self.detectorIDs = detectorIDs
        self.limitations = limitations
    }
}

public struct PolicyRule: Codable, Sendable, Equatable, Identifiable {
    public let id: PolicyRuleID
    public let source: PolicySourceReference
    public let statement: String
    public let policyArea: String
    public let applicability: String
    public let confidence: Double
    public let assumptions: [String]
    public let alternatives: [String]
    /// Optional for decoding RF-SJ-01 history written before the richer rule index existed.
    public let details: PolicyRuleDetails?
    public let controlsExecution: Bool

    public init(
        id: PolicyRuleID,
        source: PolicySourceReference,
        statement: String,
        policyArea: String,
        applicability: String,
        confidence: Double,
        assumptions: [String] = [],
        alternatives: [String] = [],
        details: PolicyRuleDetails? = nil,
        controlsExecution: Bool = false
    ) {
        self.id = id
        self.source = source
        self.statement = statement
        self.policyArea = policyArea
        self.applicability = applicability
        self.confidence = min(max(confidence, 0), 1)
        self.assumptions = assumptions
        self.alternatives = alternatives
        self.details = details
        // This field is deliberately clamped. Stjornarvald has no execution authority.
        self.controlsExecution = false
    }
}

public enum DevelopmentObservationKind: String, Codable, Sendable {
    case sessionStarted = "session_started"
    case policyContextDelivered = "policy_context_delivered"
    case agentMessageObserved = "agent_message_observed"
    case toolInvocationCompleted = "tool_invocation_completed"
    case runtimeJobObserved = "runtime_job_observed"
    case repositorySnapshotObserved = "repository_snapshot_observed"
    case dependencyStateObserved = "dependency_state_observed"
    case projectConfigurationObserved = "project_configuration_observed"
    case buildResultObserved = "build_result_observed"
    case testResultObserved = "test_result_observed"
    case documentationStateObserved = "documentation_state_observed"
    case completionClaimObserved = "completion_claim_observed"
    case handoffObserved = "handoff_observed"
    case sourceInterpretationObserved = "source_interpretation_observed"
    case engineFaultObserved = "engine_fault_observed"
}

public struct DevelopmentObservationScope: Codable, Sendable, Equatable {
    public let projectID: String?
    public let projectGeneration: Int?
    public let runID: String?
    public let sessionID: String?
    public let clientID: String?

    public init(
        projectID: String? = nil,
        projectGeneration: Int? = nil,
        runID: String? = nil,
        sessionID: String? = nil,
        clientID: String? = nil
    ) {
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.runID = runID
        self.sessionID = sessionID
        self.clientID = clientID
    }
}

public struct NativeTargetObservationEvidence: Codable, Sendable, Equatable {
    public let shippingRuntimePaths: [String]
    public let targetMembershipComplete: Bool

    public init(shippingRuntimePaths: [String], targetMembershipComplete: Bool) {
        self.shippingRuntimePaths = Array(shippingRuntimePaths.prefix(10_000))
        self.targetMembershipComplete = targetMembershipComplete
    }
}

public struct DevelopmentObservationDetails: Codable, Sendable, Equatable {
    public let nativeTarget: NativeTargetObservationEvidence?

    public init(nativeTarget: NativeTargetObservationEvidence? = nil) {
        self.nativeTarget = nativeTarget
    }
}

public struct DevelopmentObservation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let idempotencyKey: String
    public let kind: DevelopmentObservationKind
    public let observedAt: Date
    public let scope: DevelopmentObservationScope
    public let subjectIdentity: String
    public let summary: String
    public let evidenceReferences: [String]
    public let payloadSHA256: String
    public let details: DevelopmentObservationDetails?

    public init(
        id: UUID = UUID(),
        idempotencyKey: String,
        kind: DevelopmentObservationKind,
        observedAt: Date = Date(),
        scope: DevelopmentObservationScope = DevelopmentObservationScope(),
        subjectIdentity: String,
        summary: String,
        evidenceReferences: [String] = [],
        payloadSHA256: String,
        details: DevelopmentObservationDetails? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.kind = kind
        self.observedAt = observedAt
        self.scope = scope
        self.subjectIdentity = subjectIdentity
        self.summary = summary
        self.evidenceReferences = evidenceReferences
        self.payloadSHA256 = payloadSHA256
        self.details = details
    }
}

public enum PolicyViolationProjectionState: String, Codable, Sendable {
    case open, corrected, repeated, reopened, disputed
    case unresolvedAtHandoff = "unresolved_at_handoff"
}

public enum PolicyViolationEventType: String, Codable, Sendable, CaseIterable {
    case opened = "violation_opened"
    case repeated = "violation_repeated"
    case evidenceUpdated = "violation_evidence_updated"
    case corrected = "violation_corrected"
    case reopened = "violation_reopened"
    case disputed = "violation_disputed"
}

public struct PolicyViolationCandidate: Codable, Sendable, Equatable {
    public let rule: PolicyRule
    public let observationID: UUID
    public let scope: DevelopmentObservationScope
    public let subjectIdentity: String
    public let summary: String
    public let evidenceReferences: [String]
    public let explanation: String
    public let confidence: Double
    public let assumptions: [String]
    public let alternatives: [String]
    public let suggestedCorrection: String
    /// Optional to preserve the stable fingerprint of RF-SJ-01 records while
    /// allowing one rule/subject to report distinct current conditions.
    public let conditionIdentity: String?

    public init(
        rule: PolicyRule,
        observationID: UUID,
        scope: DevelopmentObservationScope = DevelopmentObservationScope(),
        subjectIdentity: String,
        summary: String,
        evidenceReferences: [String] = [],
        explanation: String,
        confidence: Double,
        assumptions: [String] = [],
        alternatives: [String] = [],
        suggestedCorrection: String,
        conditionIdentity: String? = nil
    ) {
        self.rule = rule
        self.observationID = observationID
        self.scope = scope
        self.subjectIdentity = subjectIdentity
        self.summary = summary
        self.evidenceReferences = evidenceReferences
        self.explanation = explanation
        self.confidence = min(max(confidence, 0), 1)
        self.assumptions = assumptions
        self.alternatives = alternatives
        self.suggestedCorrection = suggestedCorrection
        self.conditionIdentity = conditionIdentity
    }
}

public enum PolicyDetectorFindingDisposition: String, Codable, Sendable {
    case violation
    case correction
}

public struct PolicyDetectorFinding: Codable, Sendable, Equatable {
    public let detectorID: String
    public let disposition: PolicyDetectorFindingDisposition
    public let candidate: PolicyViolationCandidate
    public let controlsExecution: Bool

    public init(
        detectorID: String,
        disposition: PolicyDetectorFindingDisposition,
        candidate: PolicyViolationCandidate
    ) {
        self.detectorID = detectorID
        self.disposition = disposition
        self.candidate = candidate
        self.controlsExecution = false
    }
}

public struct PolicyViolation: Codable, Sendable, Equatable, Identifiable {
    public let id: PolicyViolationID
    public let fingerprint: String
    public let ruleID: PolicyRuleID
    public let policyRevision: String
    public let state: PolicyViolationProjectionState
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let occurrenceCount: Int
    public let latestSummary: String
    public let latestSuggestedCorrection: String
}

public struct PolicyViolationEvent: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: String
    public let sequence: Int64
    public let id: UUID
    public let type: PolicyViolationEventType
    public let occurredAt: Date
    public let violationID: PolicyViolationID
    public let fingerprint: String
    public let candidate: PolicyViolationCandidate
    public let noticeState: String
    public let priorEventSHA256: String?
    public let eventSHA256: String
    public let developmentContinues: Bool
}

public struct CodingAgentPolicyNotice: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let violationID: PolicyViolationID
    public let ruleReference: PolicySourceReference
    public let summary: String
    public let suggestedCorrection: String
    public let confidence: Double
    public let developmentContinues: Bool

    public init(
        id: UUID = UUID(),
        violationID: PolicyViolationID,
        ruleReference: PolicySourceReference,
        summary: String,
        suggestedCorrection: String,
        confidence: Double
    ) {
        self.id = id
        self.violationID = violationID
        self.ruleReference = ruleReference
        self.summary = summary
        self.suggestedCorrection = suggestedCorrection
        self.confidence = min(max(confidence, 0), 1)
        self.developmentContinues = true
    }
}

public enum PolicyNoticeDeliveryState: String, Codable, Sendable {
    case pending
    case presented
    case acknowledgedByTransport = "acknowledged_by_transport"
    case supersededByCorrection = "superseded_by_correction"
    case deliveryDeferred = "delivery_deferred"
}

public enum PolicyNoticeTargetKind: String, Codable, Sendable {
    case managedProvider = "managed_provider"
    case mcpClient = "mcp_client"
    case project
}

public struct PolicyNoticePresentation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let targetKind: PolicyNoticeTargetKind
    public let targetIdentity: String
    public let notices: [CodingAgentPolicyNotice]
    public let text: String
    public let digestSHA256: String
    public let controlsExecution: Bool

    public init(
        id: String,
        targetKind: PolicyNoticeTargetKind,
        targetIdentity: String,
        notices: [CodingAgentPolicyNotice],
        text: String,
        digestSHA256: String
    ) {
        self.id = id
        self.targetKind = targetKind
        self.targetIdentity = targetIdentity
        self.notices = notices
        self.text = text
        self.digestSHA256 = digestSHA256
        self.controlsExecution = false
    }
}

public struct PolicyContextSnapshot: Codable, Sendable, Equatable {
    public let policyIdentity: String
    public let applicableRuleSummaries: [String]
    public let pendingNotices: [CodingAgentPolicyNotice]
    public let limitations: [String]

    public init(
        policyIdentity: String,
        applicableRuleSummaries: [String],
        pendingNotices: [CodingAgentPolicyNotice],
        limitations: [String]
    ) {
        self.policyIdentity = policyIdentity
        self.applicableRuleSummaries = applicableRuleSummaries
        self.pendingNotices = pendingNotices
        self.limitations = limitations
    }
}

public protocol DevelopmentPolicySourceCataloging: Sendable {
    func add(selectedURL: URL, requestID: UUID) async throws -> DevelopmentPolicySource
    func refresh(sourceID: PolicySourceID, requestID: UUID) async throws
    func remove(sourceID: PolicySourceID, requestID: UUID) async throws
}

public protocol PolicyContentIndexing: Sendable {
    func schedule(sourceID: PolicySourceID) async
}

public protocol PolicyObservationSubmitting: Sendable {
    func submit(_ observation: DevelopmentObservation) async
}

public protocol PolicyViolationDetecting: Sendable {
    var detectorID: String { get }
    func evaluate(
        observation: DevelopmentObservation,
        rules: [PolicyRule]
    ) async throws -> [PolicyViolationCandidate]
}

public protocol PolicyObservationDetecting: Sendable {
    var detectorID: String { get }
    func evaluate(
        observation: DevelopmentObservation,
        rules: [PolicyRule]
    ) async throws -> [PolicyDetectorFinding]
}

public protocol PolicyViolationLogging: Sendable {
    func record(_ candidate: PolicyViolationCandidate) async throws -> PolicyViolation
}

/// Runtime-facing facade used where policy persistence is explicitly
/// non-interfering and a deferred write is preferable to a thrown failure.
public protocol FailForwardPolicyViolationLogging: Sendable {
    func record(_ candidate: PolicyViolationCandidate) async -> PolicyLogWriteDisposition
}

public enum PolicyLogWriteDisposition: Sendable, Equatable {
    case persisted(PolicyViolation)
    case deferred(eventID: UUID)
}

public protocol CodingAgentPolicyReporting: Sendable {
    func queue(_ event: PolicyViolationEvent) async
    func pendingNotices(
        projectID: String?,
        projectGeneration: Int?,
        runID: String?,
        sessionID: String?,
        clientID: String?,
        maximumCount: Int,
        maximumBytes: Int
    ) async -> [CodingAgentPolicyNotice]
}

public protocol PolicyContextProviding: Sendable {
    func context(
        projectID: String,
        projectGeneration: Int,
        runID: String,
        sessionID: String?,
        deliveryID: String,
        maximumCount: Int,
        maximumBytes: Int
    ) async -> PolicyContextSnapshot
    func presented(deliveryID: String) async
    func deferred(deliveryID: String) async
}

public protocol InteractivePolicyNoticeProviding: Sendable {
    func presentation(
        deliveryID: String,
        projectID: String?,
        projectGeneration: Int?,
        clientID: String,
        maximumCount: Int,
        maximumBytes: Int
    )
        -> PolicyNoticePresentation?
    func didPresent(_ presentation: PolicyNoticePresentation)
}

public enum PolicyLogExportFormat: String, Codable, Sendable {
    case jsonl, json, markdown, csv
}

public protocol PolicyLogExporting: Sendable {
    func export(format: PolicyLogExportFormat, destination: URL, requestID: UUID) async throws -> URL
}

public enum StjornarvaldNonInterferenceContract {
    public static let controlsToolAuthorization = false
    public static let controlsRunAdmission = false
    public static let controlsQueueState = false
    public static let controlsCompletion = false
    public static let mutatesProjectSource = false
}
