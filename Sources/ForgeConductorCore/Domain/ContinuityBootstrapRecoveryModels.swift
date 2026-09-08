// Scheduling metadata for held source recovery. Canonical continuity remains in project memory.

import Foundation

struct ContinuityBootstrapRecoveryReference: Sendable, Equatable {
    let rowID: Int64
    let operationID: UUID
    let runID: RunID
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let taskID: UUID
    let receiptSHA256: String
    let phase: ContinuitySourceRecoveryPhase

    init(rowID: Int64, operationID: UUID, runID: RunID, projectID: ProjectID,
         projectGeneration: ProjectGeneration, taskID: UUID, receiptSHA256: String,
         phase: ContinuitySourceRecoveryPhase = .bootstrap) {
        self.rowID = rowID; self.operationID = operationID; self.runID = runID
        self.projectID = projectID; self.projectGeneration = projectGeneration
        self.taskID = taskID; self.receiptSHA256 = receiptSHA256; self.phase = phase
    }
}

struct ContinuityBootstrapRecoveryDiagnostic: Sendable, Equatable {
    let rowID: Int64
    let failure: ContinuityBootstrapRecoveryFailure
}

struct ContinuityBootstrapRecoveryPage: Sendable, Equatable {
    let references: [ContinuityBootstrapRecoveryReference]
    let diagnostics: [ContinuityBootstrapRecoveryDiagnostic]
    /// Last scanned row when a full page was read; nil at the end, including an empty database.
    let nextRowID: Int64?
}

struct ContinuityBootstrapRecoveryClaim: Sendable, Equatable {
    let reference: ContinuityBootstrapRecoveryReference
    let acceptance: ContinuityIngressAcceptanceReceipt
    let claimID: UUID
    let attempt: Int
    let retryDeadline: String
}

enum ContinuityBootstrapRecoveryFailure: String, Sendable, Equatable {
    case providerUnavailable = "provider_unavailable"
    case providerOutcomeUnknown = "provider_outcome_unknown"
    case budgetExceeded = "budget_exceeded"
    case sourceUnavailable = "source_unavailable"
    case acknowledgementRejected = "acknowledgement_rejected"
    case integrityFailure = "integrity_failure"
    case interrupted
    case retryWindowExceeded = "retry_window_exceeded"
}

enum ContinuityBootstrapRecoveryOutcome: Sendable, Equatable {
    case failed(ContinuityBootstrapRecoveryFailure, retryAfter: TimeInterval?)
    case deferredPolicy
    case cancelled
}

enum ContinuityBootstrapRecoveryError: Error, LocalizedError, Sendable, Equatable {
    case policyDeferred, notDue, exhausted, claimConflict, quarantined, acknowledged, invalidRequest

    var errorDescription: String? {
        switch self {
        case .policyDeferred: "Automatic source recovery is disabled by current policy."
        case .notDue: "Source recovery is waiting for its durable retry time."
        case .exhausted: "Source recovery requires attention after its bounded retry window."
        case .claimConflict: "Source recovery no longer has this operation and lease claim."
        case .quarantined: "Source recovery metadata or its retained receipt failed integrity validation."
        case .acknowledged: "Source recovery is acknowledged and awaits final activation."
        case .invalidRequest: "Source recovery request is outside its supported bounds."
        }
    }
}

struct ContinuityBootstrapRecoveryLimits {
    static let maximumAttempts = 8
    static let retryWindow: TimeInterval = 86_400
    static let initialRetryDelay: TimeInterval = 5
    static let maximumRetryDelay: TimeInterval = 300
    static let maximumRequestedRetryDelay: TimeInterval = 3_600
    static let maximumPageSize = 128
}
