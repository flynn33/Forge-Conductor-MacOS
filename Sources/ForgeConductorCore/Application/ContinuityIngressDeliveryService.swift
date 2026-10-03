// Delivers committed source handoffs into the manager's durable admission boundary.

import Foundation

enum ContinuityIngressDeliveryCheckpoint: Sendable { case sourceClaimed, acceptanceCommitted }
enum ContinuityIngressDeliveryInterruption: Error { case simulatedExit }

struct ContinuityIngressDrainReport: Sendable, Equatable {
    var scanned = 0
    var accepted = 0
    var deferredByPolicy = 0
    var retried = 0
    var invalidated = 0
    var quarantined = 0
    var contested = 0
    var alreadyDraining = false
}

/// Owned only by the persistent manager. Its existing watchdog drives bounded
/// batches; source/MCP processes persist delivery intent but own no delivery loop.
actor ContinuityIngressDeliveryService {
    private let source: SQLiteStore
    private let repository: ProjectControlPlaneRepository
    private let config: ConfigStore
    private let diagnostics: (any DiagnosticRecording)?
    private let owner: String
    private let batchLimit: Int
    private let checkpoint: @Sendable (ContinuityIngressDeliveryCheckpoint) async throws -> Void
    private var cursor: UUID?
    private var draining = false
    private var stopped = false
    private var activeCancellation: ToolCallCancellation?
    private var activeAttemptID: UUID?
    private var activeOperationID: UUID?
    private var activeHandoffID: String?
    private var activeStage = "pending_selection"

    init(source: SQLiteStore, repository: ProjectControlPlaneRepository, config: ConfigStore,
         diagnostics: (any DiagnosticRecording)? = nil,
         owner: String = "manager-ingress-\(UUID().uuidString.lowercased())", batchLimit: Int = 16,
         checkpoint: @escaping @Sendable (ContinuityIngressDeliveryCheckpoint) async throws -> Void = { _ in }) throws {
        guard !owner.isEmpty, owner.utf8.count <= 128,
              !owner.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...ContinuityIngressLimits.maximumQueryRows).contains(batchLimit) else {
            throw ContinuityIngressError.invalidRequest("manager_delivery_owner_or_batch")
        }
        self.source = source
        self.repository = repository
        self.config = config
        self.diagnostics = diagnostics
        self.owner = owner
        self.batchLimit = batchLimit
        self.checkpoint = checkpoint
    }

    func shutdown() {
        stopped = true
        activeCancellation?.cancel()
    }

    func drainOnce(attemptID: UUID = UUID()) async throws -> ContinuityIngressDrainReport {
        guard !stopped else { throw AutonomyError.shutdown }
        guard !draining else { return ContinuityIngressDrainReport(alreadyDraining: true) }
        draining = true
        activeAttemptID = attemptID
        activeOperationID = nil
        activeHandoffID = nil
        activeStage = "pending_selection"
        let cancellation = ToolCallCancellation(timeoutSeconds: 8)
        activeCancellation = cancellation
        defer {
            activeCancellation = nil
            activeAttemptID = nil
            activeOperationID = nil
            activeHandoffID = nil
            draining = false
        }
        do {
            return try await withTaskCancellationHandler {
                try await drainBatch(cancellation: cancellation)
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            let observed = activeOperationID.flatMap { try? source.continuityDelivery(operationID: $0) }
            diagnostics?.warn("continuity_ingress_drain_failed", [
                "attempt_id": attemptID.uuidString,
                "operation_id": activeOperationID?.uuidString ?? "unavailable_before_operation_selection",
                "handoff_id": activeHandoffID ?? (activeOperationID == nil
                    ? "unavailable_before_operation_selection" : "unavailable_before_delivery_load"),
                "failure_stage": activeStage,
                "successor_request_state": "not_requested_by_ingress",
                "delivery_state": observed?.state.rawValue ?? "unavailable_at_failure",
                "attempt_count": observed.map { "\($0.attempts)" } ?? "unavailable_at_failure",
                "next_attempt_at": observed?.nextAttemptAt ?? "unavailable_at_failure",
                "claim_expires_at": observed?.leaseExpiresAt ?? "not_applicable_or_unavailable",
                "disposition": observed?.state.rawValue ?? "unconfirmed_at_failure",
                "error": error.localizedDescription,
                "error_type": String(reflecting: type(of: error)),
                "error_domain": (error as NSError).domain,
                "error_numeric_code": "\((error as NSError).code)",
            ], category: .manager)
            throw error
        }
    }

    private func drainBatch(cancellation: ToolCallCancellation) async throws -> ContinuityIngressDrainReport {
        var report = ContinuityIngressDrainReport()
        activeStage = "pending_selection"
        var identifiers = try source.pendingContinuityHandoffIDs(
            limit: batchLimit, afterOperationID: cursor, cancellation: cancellation
        )
        if identifiers.isEmpty, cursor != nil {
            cursor = nil
            identifiers = try source.pendingContinuityHandoffIDs(limit: batchLimit, cancellation: cancellation)
        }
        for identifier in identifiers {
            try checkCancellation(cancellation)
            cursor = identifier
            activeOperationID = identifier
            activeHandoffID = nil
            activeStage = "delivery_load"
            report.scanned += 1
            let delivery: ContinuityHandoffDelivery
            do {
                guard let stored = try source.continuityDelivery(operationID: identifier, cancellation: cancellation) else {
                    continue
                }
                delivery = stored
                activeHandoffID = stored.handoff.identity.continuityID
                diagnostics?.info("continuity_ingress_attempt", [
                    "attempt_id": activeAttemptID?.uuidString ?? "unavailable_before_drain",
                    "operation_id": identifier.uuidString,
                    "handoff_id": stored.handoff.identity.continuityID,
                    "attempt_count_before_claim": "\(stored.attempts)",
                    "delivery_state": stored.state.rawValue,
                    "handoff_delivery_requested": stored.explicitlyRequested ? "true" : "false",
                    "successor_request_state": "not_requested_by_ingress",
                ], category: .manager)
            } catch let error as ContinuityIngressError {
                guard case .integrityFailure = error else { throw error }
                if try source.quarantineMalformedContinuityDelivery(operationID: identifier, cancellation: cancellation) {
                    report.quarantined += 1
                }
                continue
            }

            // This snapshot comes from the authoritative config file, not a tool
            // argument or the packet. Bootstrap must revalidate it before effects.
            let scope = BudgetPolicyScope(kind: .projectOverride,
                projectID: delivery.handoff.authorization.projectID.description,
                projectGeneration: Int(delivery.handoff.authorization.projectGeneration.rawValue))
            let selection: BudgetPolicySelection
            activeStage = "policy_selection"
            do { selection = try config.budgetPolicySelection(scope: scope) }
            catch {
                try checkCancellation(cancellation)
                // An unavailable policy grants no delivery or provider authority.
                // Keep the source intent untouched for later repaired settings.
                report.deferredByPolicy += 1
                continue
            }
            guard delivery.explicitlyRequested || selection.policy.automaticHandoffEnabled else {
                report.deferredByPolicy += 1
                continue
            }
            try checkCancellation(cancellation)
            let claim: ContinuityDeliveryClaim
            activeStage = "source_claim"
            do {
                guard let owned = try source.claimContinuityHandoff(
                    operationID: identifier, owner: owner, leaseSeconds: 30, cancellation: cancellation
                ) else {
                    report.contested += 1
                    continue
                }
                claim = owned
            } catch let error as ContinuityIngressError {
                guard try handleSourceRace(error, operationID: identifier, cancellation: cancellation, report: &report) else {
                    throw error
                }
                continue
            }
            do {
                activeStage = "source_claimed_checkpoint"
                try await checkpoint(.sourceClaimed)
                try checkCancellation(cancellation)
                activeStage = "claim_validation"
                _ = try source.validateContinuityHandoffClaim(claim: claim, cancellation: cancellation)
                activeStage = "admission_policy_selection"
                let admissionSelection = try config.budgetPolicySelection(scope: scope)
                if !admissionSelection.policy.automaticHandoffEnabled {
                    // Policy may change while waiting for the claim or manager.
                    // Explicit promotion is monotonic and checked under the same
                    // source transaction that releases an unsubmitted claim.
                    if try source.deferUnsubmittedContinuityHandoff(claim: claim, cancellation: cancellation) {
                        report.deferredByPolicy += 1
                        continue
                    }
                }
                activeStage = "manager_acceptance"
                let receipt = try await repository.acceptContinuityIngress(
                    source: claim.delivery.handoff, operationID: identifier,
                    policySelection: admissionSelection, cancellation: cancellation
                )
                guard receipt.operationID == identifier,
                      receipt.sourceIdentity == claim.delivery.handoff.identity,
                      receipt.authorization == claim.delivery.handoff.authorization else {
                    throw ContinuityIngressError.integrityFailure("manager acceptance names a different source")
                }
                activeStage = "acceptance_committed_checkpoint"
                try await checkpoint(.acceptanceCommitted)
                try checkCancellation(cancellation)
                activeStage = "source_acknowledgement"
                _ = try source.acknowledgeContinuityHandoff(
                    claim: claim, acceptanceReceiptSHA256: receipt.receiptSHA256,
                    cancellation: cancellation
                )
                report.accepted += 1
            } catch is ContinuityIngressDeliveryInterruption {
                // An actual process exit leaves the same durable claim and any
                // committed acceptance; this seam exercises that recovery boundary.
                throw ContinuityIngressDeliveryInterruption.simulatedExit
            } catch {
                let failedStage = activeStage
                if Task.isCancelled || cancellation.isCancelled || cancellation.isDeadlineExceeded || stopped {
                    throw error
                }
                if let sourceError = error as? ContinuityIngressError,
                   try handleSourceRace(sourceError, operationID: identifier, cancellation: cancellation, report: &report) {
                    continue
                }
                if let authorityError = error as? ContinuityTaskAuthorizationError, authorityError == .revoked {
                    _ = try source.invalidateContinuityIngress(
                        projectID: claim.delivery.handoff.authorization.projectID,
                        throughGeneration: claim.delivery.handoff.authorization.projectGeneration,
                        taskID: claim.delivery.handoff.authorization.taskID,
                        cancellation: cancellation
                    )
                    report.invalidated += 1
                    continue
                }
                do {
                    activeStage = "retry_scheduling"
                    let retryDelay = Double(1 << min(claim.delivery.attempts, 8))
                    let retried = try source.retryContinuityHandoff(
                        claim: claim, errorCode: Self.errorCode(error),
                        retryDelaySeconds: retryDelay,
                        cancellation: cancellation
                    )
                    diagnostics?.warn("continuity_ingress_retry_scheduled", [
                        "attempt_id": activeAttemptID?.uuidString ?? "unavailable_before_drain",
                        "operation_id": identifier.uuidString,
                        "handoff_id": claim.delivery.handoff.identity.continuityID,
                        "failure_stage": failedStage,
                        "recovery_stage": "retry_scheduling",
                        "successor_request_state": "not_requested_by_ingress",
                        "delivery_state": retried.state.rawValue,
                        "attempt_count": "\(retried.attempts)",
                        "retry_delay_seconds": "\(Int(retryDelay))",
                        "next_attempt_at": retried.nextAttemptAt,
                        "claim_expires_at": retried.leaseExpiresAt ?? "not_applicable_claim_released",
                        "disposition": retried.state == .pending ? "retry_scheduled" : retried.state.rawValue,
                        "error": error.localizedDescription,
                        "error_type": String(reflecting: type(of: error)),
                        "error_domain": (error as NSError).domain,
                        "error_numeric_code": "\((error as NSError).code)",
                    ], category: .manager)
                    report.retried += 1
                } catch let sourceError as ContinuityIngressError {
                    guard try handleSourceRace(sourceError, operationID: identifier,
                        cancellation: cancellation, report: &report) else { throw sourceError }
                }
            }
        }
        return report
    }

    private func handleSourceRace(_ error: ContinuityIngressError, operationID: UUID,
                                  cancellation: ToolCallCancellation,
                                  report: inout ContinuityIngressDrainReport) throws -> Bool {
        try checkCancellation(cancellation)
        switch error {
        case .invalidated:
            report.invalidated += 1
        case .deliveryConflict:
            report.contested += 1
        case .integrityFailure:
            if try source.quarantineMalformedContinuityDelivery(operationID: operationID, cancellation: cancellation) {
                report.quarantined += 1
            } else {
                // A live lease cannot be quarantined through an unowned update.
                // Keep its claim for bounded expiry/reconciliation and advance.
                report.contested += 1
            }
        default:
            return false
        }
        return true
    }

    private func checkCancellation(_ cancellation: ToolCallCancellation) throws {
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        if stopped { throw AutonomyError.shutdown }
    }

    private static func errorCode(_ error: Error) -> String {
        switch error {
        case is ContinuityTaskAuthorizationError: "task_authorization_rejected"
        case is ProjectContextError: "project_admission_rejected"
        case is ContinuityIngressError: "handoff_admission_rejected"
        default: "manager_admission_failed"
        }
    }
}
