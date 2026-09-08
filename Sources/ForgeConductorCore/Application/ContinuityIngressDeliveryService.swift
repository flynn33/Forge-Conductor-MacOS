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
    private let owner: String
    private let batchLimit: Int
    private let checkpoint: @Sendable (ContinuityIngressDeliveryCheckpoint) async throws -> Void
    private var cursor: UUID?
    private var draining = false
    private var stopped = false
    private var activeCancellation: ToolCallCancellation?

    init(source: SQLiteStore, repository: ProjectControlPlaneRepository, config: ConfigStore,
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
        self.owner = owner
        self.batchLimit = batchLimit
        self.checkpoint = checkpoint
    }

    func shutdown() {
        stopped = true
        activeCancellation?.cancel()
    }

    func drainOnce() async throws -> ContinuityIngressDrainReport {
        guard !stopped else { throw AutonomyError.shutdown }
        guard !draining else { return ContinuityIngressDrainReport(alreadyDraining: true) }
        draining = true
        let cancellation = ToolCallCancellation(timeoutSeconds: 8)
        activeCancellation = cancellation
        defer {
            activeCancellation = nil
            draining = false
        }
        return try await withTaskCancellationHandler {
            try await drainBatch(cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func drainBatch(cancellation: ToolCallCancellation) async throws -> ContinuityIngressDrainReport {
        var report = ContinuityIngressDrainReport()
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
            report.scanned += 1
            let delivery: ContinuityHandoffDelivery
            do {
                guard let stored = try source.continuityDelivery(operationID: identifier, cancellation: cancellation) else {
                    continue
                }
                delivery = stored
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
                try await checkpoint(.sourceClaimed)
                try checkCancellation(cancellation)
                _ = try source.validateContinuityHandoffClaim(claim: claim, cancellation: cancellation)
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
                let receipt = try await repository.acceptContinuityIngress(
                    source: claim.delivery.handoff, operationID: identifier,
                    policySelection: admissionSelection, cancellation: cancellation
                )
                guard receipt.operationID == identifier,
                      receipt.sourceIdentity == claim.delivery.handoff.identity,
                      receipt.authorization == claim.delivery.handoff.authorization else {
                    throw ContinuityIngressError.integrityFailure("manager acceptance names a different source")
                }
                try await checkpoint(.acceptanceCommitted)
                try checkCancellation(cancellation)
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
                    _ = try source.retryContinuityHandoff(
                        claim: claim, errorCode: Self.errorCode(error),
                        retryDelaySeconds: Double(1 << min(claim.delivery.attempts, 8)),
                        cancellation: cancellation
                    )
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
