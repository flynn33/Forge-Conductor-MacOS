// One supervisor-owned activation of a held source operation.

import Foundation

actor ManagedSourceBootstrapCoordinator: ProjectRunCoordinating {
    typealias Bootstrap = @Sendable (ContinuityIngressAcceptanceReceipt, RunLease) async throws -> SourceBootstrapReceipt
    typealias CancelBootstrap = @Sendable (UUID) async -> Void
    typealias ReadCanonical = @Sendable (ContinuityIngressAcceptanceReceipt) throws -> ContinuitySourceBootstrapOperation
    typealias ActivateSource = @Sendable (ContinuityIngressAcceptanceReceipt, RunLease) async throws -> AutonomousRunRecord

    nonisolated let runID: RunID
    private let reference: ContinuityBootstrapRecoveryReference
    private let repository: ProjectControlPlaneRepository
    private let managerID: String
    private let leasePolicy: RunLeasePolicy
    private let clock: any Clock
    private let sleeper: any AutonomySleeping
    private let policyResolver: PersistedManagedRunBudgetEvaluator.PolicyResolver
    private let bootstrap: Bootstrap
    private let cancelBootstrap: CancelBootstrap
    private let readCanonical: ReadCanonical
    private let activateSource: ActivateSource?
    private var stopped = false
    private var activationStarted = false
    private var activation: Task<ProjectRunActivationResult, Error>?
    private var ownedLease: RunLease?
    private var bootstrapStarted = false
    private var cancellationIssued = false

    init(reference: ContinuityBootstrapRecoveryReference, repository: ProjectControlPlaneRepository,
         managerID: String, leasePolicy: RunLeasePolicy = .init(), clock: any Clock = SystemClock(),
         sleeper: any AutonomySleeping = SystemAutonomySleeper(),
         policyResolver: @escaping PersistedManagedRunBudgetEvaluator.PolicyResolver,
         bootstrap: @escaping Bootstrap, cancelBootstrap: @escaping CancelBootstrap,
         readCanonical: @escaping ReadCanonical, activateSource: ActivateSource? = nil) throws {
        guard !managerID.isEmpty, managerID.utf8.count <= 512,
              managerID == managerID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AutonomyError.invalidRequest("source coordinator requires a bounded manager identity")
        }
        self.runID = reference.runID
        self.reference = reference
        self.repository = repository
        self.managerID = managerID
        self.leasePolicy = leasePolicy
        self.clock = clock
        self.sleeper = sleeper
        self.policyResolver = policyResolver
        self.bootstrap = bootstrap
        self.cancelBootstrap = cancelBootstrap
        self.readCanonical = readCanonical
        self.activateSource = activateSource
    }

    func runActivation() async throws -> ProjectRunActivationResult {
        guard !stopped else { throw AutonomyError.shutdown }
        guard !activationStarted else { throw AutonomyError.invalidRequest("source coordinator owns one activation") }
        try Task.checkCancellation()
        activationStarted = true
        let task = Task { try await self.performActivation() }
        activation = task
        defer { activation = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stop() async {
        // Set this before suspending so a queued lease/claim completion cannot
        // bind a late provider operation after shutdown has begun.
        stopped = true
        let task = activation
        task?.cancel()
        await cancelOwnedBootstrap()
        if let task { _ = try? await task.value }
    }

    private func performActivation() async throws -> ProjectRunActivationResult {
        try requireRunning()
        guard reference.phase == .bootstrap || (reference.phase == .activation && activateSource != nil) else {
            throw AutonomyError.invalidRequest("source activation recovery requires its native activation owner")
        }
        let lease = try await repository.acquireRunLease(runID: runID, ownerID: managerID, policy: leasePolicy)
        ownedLease = lease
        var claim: ContinuityBootstrapRecoveryClaim?
        do {
            try requireRunning()
            let claimed = try await repository.claimContinuityBootstrapRecovery(reference: reference,
                lease: lease, policy: currentPolicy())
            claim = claimed
            try requireRunning()
            // Policy may change while the claim transaction is queued. Refund
            // only this pre-dispatch opt-out, never a possibly submitted request.
            do {
                _ = try await repository.validateContinuitySourceStartAuthority(
                    acceptance: claimed.acceptance, lease: lease, policySelection: currentPolicy())
            } catch ContinuityBootstrapRecoveryError.policyDeferred {
                try await repository.finishContinuityBootstrapRecovery(claim: claimed, lease: lease, outcome: .deferredPolicy)
                try await releaseOwnedLease()
                return try await result(steps: 0)
            }
            try requireRunning()
            let repository = self.repository, bootstrap = self.bootstrap, readCanonical = self.readCanonical
            let activateSource = self.activateSource
            bootstrapStarted = claimed.reference.phase == .bootstrap
            let protected = try await RunLeaseProtection.withRenewal(lease, repository: repository,
                policy: leasePolicy, sleeper: sleeper) {
                try Task.checkCancellation()
                switch claimed.reference.phase {
                case .bootstrap:
                    let receipt = try await bootstrap(claimed.acceptance, lease)
                    try Task.checkCancellation()
                    guard receipt.retrieval.operationID == claimed.reference.operationID,
                          receipt.retrieval.runID == claimed.reference.runID,
                          receipt.retrieval.sourceIdentity == claimed.acceptance.sourceIdentity else {
                        throw ContinuityIngressError.authorityMismatch
                    }
                    guard let current = try await repository.runLease(lease.runID),
                          current.ownerID == lease.ownerID, current.epoch == lease.epoch else {
                        throw AutonomyError.staleLease
                    }
                    try Task.checkCancellation()
                    // ACK retains the hold. The next existing-watchdog recovery
                    // performs activation without repeating either provider turn.
                    try await repository.markContinuityBootstrapAcknowledged(claim: claimed, lease: current) {
                        try readCanonical(claimed.acceptance)
                    }
                case .activation:
                    guard let activateSource,
                          let current = try await repository.runLease(lease.runID),
                          current.ownerID == lease.ownerID, current.epoch == lease.epoch else {
                        throw AutonomyError.staleLease
                    }
                    try Task.checkCancellation()
                    let activated = try await activateSource(claimed.acceptance, current)
                    try Task.checkCancellation()
                    let admitted = try await repository.validateAutonomousRunExecutionAdmission(claimed.reference.runID)
                    guard activated.runID == claimed.reference.runID,
                          activated.projectID == claimed.reference.projectID,
                          activated.projectGeneration == claimed.reference.projectGeneration,
                          activated.activeSessionID != nil,
                          admitted.activeSessionID == activated.activeSessionID,
                          admitted.activeOperationID == claimed.reference.operationID else {
                        throw ContinuityIngressError.authorityMismatch
                    }
                }
            }
            ownedLease = protected.lease
            try await releaseOwnedLease()
            return try await result(steps: 1)
        } catch {
            await cancelOwnedBootstrap()
            var cleanupError: (any Error)?
            if let claim {
                do {
                    if let current = try await currentOwnedLease(),
                       current.expirationDate.map({ $0 > clock.now() }) == true {
                        let outcome: ContinuityBootstrapRecoveryOutcome = stopped || error is CancellationError
                            ? .cancelled : Self.failureOutcome(error)
                        try await repository.finishContinuityBootstrapRecovery(claim: claim, lease: current, outcome: outcome)
                    }
                } catch let failure as ContinuityBootstrapRecoveryError where failure == .claimConflict || failure == .acknowledged {
                    // A committed ACK or another owner is not ours to overwrite.
                } catch let failure as AutonomyError where failure == .staleLease || failure == .leaseExpired {
                    // Lease expiry is reconciled by the existing supervisor.
                } catch let failure as ContinuityIngressError where failure == .authorityMismatch || failure == .invalidated {
                    // Durable user cancellation or invalidation owns that state.
                } catch let failure as ContinuityOperationControlError where failure == .cancellationRequested || failure == .conflict {
                    // Exact durable cancellation owns cleanup and retry state.
                } catch {
                    cleanupError = error
                }
            }
            do { try await releaseOwnedLease() } catch { cleanupError = error }
            if let cleanupError { throw cleanupError }
            throw error
        }
    }

    private func requireRunning() throws {
        try Task.checkCancellation()
        guard !stopped else { throw AutonomyError.shutdown }
    }

    private func currentPolicy() throws -> BudgetPolicySelection {
        guard let generation = Int(exactly: reference.projectGeneration.rawValue) else {
            throw ContextBudgetError.invalidPolicy
        }
        return try policyResolver(BudgetPolicyScope(kind: .projectOverride,
            projectID: reference.projectID.description, projectGeneration: generation))
    }

    private func cancelOwnedBootstrap() async {
        guard ownedLease != nil, bootstrapStarted, !cancellationIssued else { return }
        cancellationIssued = true
        await cancelBootstrap(reference.operationID)
    }

    private func currentOwnedLease() async throws -> RunLease? {
        guard let owned = ownedLease, let current = try await repository.runLease(runID),
              current.ownerID == owned.ownerID, current.epoch == owned.epoch else { return nil }
        return current
    }

    private func releaseOwnedLease() async throws {
        guard let owned = ownedLease else { return }
        // The repository deletion predicate includes owner and epoch. Even a
        // replacement lease for this run cannot be released by this activation.
        _ = try await repository.releaseRunLease(owned)
        ownedLease = nil
    }

    private func result(steps: Int) async throws -> ProjectRunActivationResult {
        guard let run = try await repository.autonomousRun(runID) else { throw AutonomyError.runNotFound(runID) }
        return ProjectRunActivationResult(runID: runID, finalState: run.state, stepsExecuted: steps, yielded: !run.state.isTerminal)
    }

    private static func failureOutcome(_ error: any Error) -> ContinuityBootstrapRecoveryOutcome {
        if let provider = error as? any ManagedProviderFailure {
            let code = provider.managedProviderFailureCode
            let unknown = ["lmstudio_conflict", "lmstudio_deadline_exceeded", "lmstudio_receipt_storage"].contains(code)
            if unknown {
                return .failed(.providerOutcomeUnknown, retryAfter: max(660, provider.managedProviderRetryDelay ?? 0))
            }
            switch provider.managedProviderFailureDisposition {
            case .cancelled: return .cancelled
            case .contextOverflow: return .failed(.budgetExceeded, retryAfter: nil)
            case .waitingProvider, .blockedConfiguration:
                return .failed(.providerUnavailable, retryAfter: provider.managedProviderRetryDelay)
            case .failedRecoverable, .failedTerminal:
                return .failed(.acknowledgementRejected, retryAfter: provider.managedProviderRetryDelay)
            }
        }
        if error is ContextBudgetError { return .failed(.budgetExceeded, retryAfter: nil) }
        if let ingress = error as? ContinuityIngressError {
            switch ingress {
            case .capacityExceeded: return .failed(.budgetExceeded, retryAfter: nil)
            case .notFound: return .failed(.sourceUnavailable, retryAfter: nil)
            default: return .failed(.integrityFailure, retryAfter: nil)
            }
        }
        return .failed(.interrupted, retryAfter: 660)
    }
}
