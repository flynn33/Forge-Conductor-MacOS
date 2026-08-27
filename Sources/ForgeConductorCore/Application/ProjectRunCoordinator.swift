// ProjectRunCoordinator.swift
// Serializes one durable run, persists each side-effect intent, and gates completion.

import Foundation

public enum ProjectRunStepOutcome: Sendable, Equatable {
    case continued(AutonomousRunWork)
    case checkpointRequired(AutonomousRunWork)
    case rolloverRequired(AutonomousRunWork)
    case completionRequested(String)
    case completionRequestedWithWork(String, AutonomousRunWork)
    case waitingProvider(code: String, summary: String)
    case waitingResource(code: String, summary: String)
    case paused(String)
    case failedRecoverable(code: String, summary: String)
    case failedTerminal(code: String, summary: String)
    case cancelled
}

public protocol ProjectRunStepExecuting: Sendable {
    /// Returns the identity to commit before external work. `nil` yields the run without
    /// manufacturing an external action.
    func prepareNextStep(for run: AutonomousRunRecord) async throws -> RunSideEffectIntent?

    func execute(
        _ intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome

    func cancel(runID: RunID) async
}

public protocol RunCompletionValidating: Sendable {
    func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt
}

public protocol AutonomySleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemAutonomySleeper: AutonomySleeping, Sendable {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct CompletionGateValidator: Sendable {
    public let gate: String
    private let operation: @Sendable (AutonomousRunRecord) async throws -> CompletionGateResult

    public init(
        gate: String,
        operation: @escaping @Sendable (AutonomousRunRecord) async throws -> CompletionGateResult
    ) {
        self.gate = gate
        self.operation = operation
    }

    public func evaluate(_ run: AutonomousRunRecord) async throws -> CompletionGateResult {
        try await operation(run)
    }
}

public struct DeterministicCompletionValidator: RunCompletionValidating, Sendable {
    private let validators: [String: CompletionGateValidator]
    private let clock: any Clock

    public init(
        validators: [CompletionGateValidator],
        clock: any Clock = SystemClock()
    ) throws {
        guard !validators.isEmpty, validators.count <= 256,
              Set(validators.map(\.gate)).count == validators.count else {
            throw AutonomyError.invalidRequest("completion validators must be unique and bounded")
        }
        self.validators = Dictionary(uniqueKeysWithValues: validators.map { ($0.gate, $0) })
        self.clock = clock
    }

    public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
        guard run.state == .validatingCompletion else {
            throw AutonomyError.completionValidationRequired
        }
        var results: [CompletionGateResult] = []
        results.reserveCapacity(run.specification.completionGates.count)
        for gate in run.specification.completionGates {
            guard let validator = validators[gate] else {
                results.append(CompletionGateResult(
                    gate: gate,
                    passed: false,
                    summary: "No deterministic validator is registered for this gate"
                ))
                continue
            }
            let result = try await validator.evaluate(run)
            guard result.gate == gate else {
                throw AutonomyError.invalidRequest("completion validator returned the wrong gate identity")
            }
            guard result.summary.utf8.count <= 2_048,
                  result.evidenceReferences.count <= 256,
                  result.evidenceReferences.allSatisfy({ $0.utf8.count <= 2_048 }) else {
                throw AutonomyError.invalidRequest("completion result exceeds its durable bound")
            }
            results.append(result)
        }
        return try CompletionValidationReceipt.make(
            runID: run.runID,
            expectedRevision: run.revision,
            results: results,
            validatedAt: ISO8601.string(from: clock.now())
        )
    }
}

public struct AutonomyRetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let totalDeadline: TimeInterval

    public init(
        maximumAttempts: Int = 5,
        baseDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60,
        totalDeadline: TimeInterval = 300
    ) {
        self.maximumAttempts = maximumAttempts
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.totalDeadline = totalDeadline
    }

    public func delay(attempt: Int, deterministicSeed: UInt64) throws -> TimeInterval {
        guard (1...20).contains(maximumAttempts), attempt >= 1, attempt <= maximumAttempts,
              baseDelay > 0, maximumDelay >= baseDelay,
              totalDeadline >= baseDelay, totalDeadline <= 86_400 else {
            throw AutonomyError.invalidRequest("retry policy or attempt is outside bounded limits")
        }
        let exponent = min(attempt - 1, 20)
        let exponential = min(maximumDelay, baseDelay * pow(2, Double(exponent)))
        let jitterUnit = Double(deterministicSeed % 10_001) / 10_000
        return min(totalDeadline, exponential * (0.75 + (0.5 * jitterUnit)))
    }

    public static func deterministicSeed(runID: RunID, attempt: Int) -> UInt64 {
        let digest = JSONSupport.sha256Hex("\(runID.description):\(attempt)")
        return UInt64(digest.prefix(16), radix: 16) ?? 0
    }
}

public struct ProjectRunActivationResult: Sendable, Equatable {
    public let runID: RunID
    public let finalState: AutonomousRunState
    public let stepsExecuted: Int
    public let yielded: Bool
}

public actor ProjectRunCoordinator {
    public static let maximumStepsPerActivation = 64

    public nonisolated let runID: RunID

    private let repository: ProjectControlPlaneRepository
    private let managerID: String
    private let leasePolicy: RunLeasePolicy
    private let retryPolicy: AutonomyRetryPolicy
    private let stepExecutor: any ProjectRunStepExecuting
    private let completionValidator: any RunCompletionValidating
    private let clock: any Clock
    private let sleeper: any AutonomySleeping
    private let maximumSteps: Int
    private var stopped = false

    public init(
        runID: RunID,
        repository: ProjectControlPlaneRepository,
        managerID: String,
        leasePolicy: RunLeasePolicy = .init(),
        retryPolicy: AutonomyRetryPolicy = .init(),
        stepExecutor: any ProjectRunStepExecuting,
        completionValidator: any RunCompletionValidating,
        clock: any Clock = SystemClock(),
        sleeper: any AutonomySleeping = SystemAutonomySleeper(),
        maximumSteps: Int = ProjectRunCoordinator.maximumStepsPerActivation
    ) throws {
        guard (1...Self.maximumStepsPerActivation).contains(maximumSteps) else {
            throw AutonomyError.invalidRequest("activation step limit must be between 1 and 64")
        }
        self.runID = runID
        self.repository = repository
        self.managerID = managerID
        self.leasePolicy = leasePolicy
        self.retryPolicy = retryPolicy
        self.stepExecutor = stepExecutor
        self.completionValidator = completionValidator
        self.clock = clock
        self.sleeper = sleeper
        self.maximumSteps = maximumSteps
    }

    public func stop() async {
        stopped = true
        await stepExecutor.cancel(runID: runID)
    }

    public func runActivation() async throws -> ProjectRunActivationResult {
        guard !stopped else { throw AutonomyError.shutdown }
        var lease = try await repository.acquireRunLease(
            runID: runID,
            ownerID: managerID,
            policy: leasePolicy
        )
        do {
            var run = try await repository.validateAutonomousRunGeneration(runID)
            var steps = 0
            while !stopped, steps < maximumSteps, !run.state.isTerminal {
            lease = try await repository.renewRunLease(lease, policy: leasePolicy)
            if run.state == .paused || run.state == .blockedConfiguration {
                break
            }
            if run.state == .cancelRequested {
                await stepExecutor.cancel(runID: runID)
                run = try await transition(
                    run,
                    to: .cancelled,
                    lease: lease,
                    event: "autonomous_run_cancelled",
                    summary: "Cancellation completed"
                )
                break
            }
            if run.state == .validatingCompletion {
                run = try await validateCompletion(run, lease: lease)
                steps += 1
                continue
            }
            if let next = try await bootstrapState(run, lease: lease) {
                run = next
                steps += 1
                continue
            }
            guard run.state == .running || run.state == .checkpointing
                    || run.state == .rollingOver || run.state == .recovering else {
                break
            }
            let preparationRun = run
            let prepared = try await withLeaseRenewal(lease) { [stepExecutor, preparationRun] in
                try await stepExecutor.prepareNextStep(for: preparationRun)
            }
            lease = prepared.lease
            guard let intent = prepared.value else {
                break
            }
            run = try await repository.persistRunSideEffectIntent(
                runID: runID,
                lease: lease,
                expectedRevision: run.revision,
                intent: intent
            )
            let context = try await invocationContext(for: run)
            do {
                let executionRun = run
                let executionLease = lease
                let protected = try await withLeaseRenewal(lease) {
                    [stepExecutor, executionRun, executionLease] in
                    try await stepExecutor.execute(
                        intent,
                        run: executionRun,
                        context: context,
                        lease: executionLease
                    )
                }
                lease = protected.lease
                let outcome = protected.value
                // The executor may durably reserve a provider session, persist a
                // continuity operation, or otherwise advance the run revision while
                // performing the side effect. Re-read before applying the outcome so
                // the coordinator never writes with a stale compare-and-swap token.
                guard let refreshedRun = try await repository.autonomousRun(runID) else {
                    throw AutonomyError.runNotFound(runID)
                }
                run = try await apply(outcome, to: refreshedRun, lease: lease)
            } catch {
                guard let refreshedRun = try await repository.autonomousRun(runID) else {
                    throw AutonomyError.runNotFound(runID)
                }
                run = refreshedRun
                // Manager shutdown and supervisor quiescence cancel owned resources but
                // intentionally retain the durable run and exact pending intent. A later
                // manager instance reconciles the ambiguous provider turn before retrying.
                if stopped || error is CancellationError {
                    break
                }
                let attempt = max(1, steps + 1)
                let seed = AutonomyRetryPolicy.deterministicSeed(runID: runID, attempt: attempt)
                let policyDelay = try retryPolicy.delay(
                    attempt: min(attempt, retryPolicy.maximumAttempts),
                    deterministicSeed: seed
                )
                let summary = String(error.localizedDescription.prefix(2_048))
                if let failure = error as? any ManagedProviderFailure {
                    switch failure.managedProviderFailureDisposition {
                    case .waitingProvider:
                        let providerDelay = failure.managedProviderRetryDelay
                        let requestedDelay = if let providerDelay,
                                                providerDelay.isFinite,
                                                providerDelay > 0 {
                            providerDelay
                        } else {
                            policyDelay
                        }
                        let delay = min(
                            retryPolicy.totalDeadline,
                            max(retryPolicy.baseDelay, min(retryPolicy.maximumDelay, requestedDelay))
                        )
                        run = try await transition(
                            run, to: .waitingProvider, lease: lease,
                            event: "autonomous_run_waiting_provider",
                            summary: "Managed provider is temporarily unavailable",
                            errorCode: failure.managedProviderFailureCode,
                            errorSummary: summary,
                            retryAt: ISO8601.string(from: clock.now().addingTimeInterval(delay))
                        )
                    case .blockedConfiguration:
                        run = try await transition(
                            run, to: .blockedConfiguration, lease: lease,
                            event: "autonomous_run_configuration_blocked",
                            summary: "Managed provider configuration requires correction",
                            errorCode: failure.managedProviderFailureCode,
                            errorSummary: summary
                        )
                    case .cancelled:
                        run = try await transition(
                            run, to: .cancelRequested, lease: lease,
                            event: "autonomous_run_cancel_requested",
                            summary: "Managed provider request was cancelled",
                            errorCode: failure.managedProviderFailureCode,
                            errorSummary: summary
                        )
                    case .contextOverflow, .failedRecoverable:
                        run = try await transition(
                            run, to: .failedRecoverable, lease: lease,
                            event: "autonomous_run_failed_recoverable",
                            summary: "Managed provider execution can be recovered",
                            errorCode: failure.managedProviderFailureCode,
                            errorSummary: summary
                        )
                    case .failedTerminal:
                        run = try await transition(
                            run, to: .failedTerminal, lease: lease,
                            event: "autonomous_run_failed_terminal",
                            summary: "Managed provider execution failed terminally",
                            errorCode: failure.managedProviderFailureCode,
                            errorSummary: summary
                        )
                    }
                } else {
                    run = try await transition(
                        run,
                        to: .waitingProvider,
                        lease: lease,
                        event: "autonomous_run_waiting_provider",
                        summary: "Run yielded after a transient execution failure",
                        errorCode: "run_step_failed",
                        errorSummary: summary,
                        retryAt: ISO8601.string(
                            from: clock.now().addingTimeInterval(policyDelay)
                        )
                    )
                }
                break
            }
                steps += 1
            }
            let result = ProjectRunActivationResult(
                runID: runID,
                finalState: run.state,
                stepsExecuted: steps,
                yielded: !run.state.isTerminal
            )
            _ = try await repository.releaseRunLease(lease)
            return result
        } catch {
            _ = try? await repository.releaseRunLease(lease)
            throw error
        }
    }

    private func bootstrapState(
        _ run: AutonomousRunRecord,
        lease: RunLease
    ) async throws -> AutonomousRunRecord? {
        switch run.state {
        case .created:
            return try await transition(
                run, to: .validating, lease: lease,
                event: "autonomous_run_validation_started",
                summary: "Durable run validation started"
            )
        case .validating:
            _ = try await repository.validateAutonomousRunGeneration(run.runID)
            guard run.providerID?.isEmpty == false, run.modelKey?.isEmpty == false else {
                return try await transition(
                    run, to: .blockedConfiguration, lease: lease,
                    event: "autonomous_run_configuration_blocked",
                    summary: "Provider or model configuration is missing",
                    errorCode: "provider_configuration_missing",
                    errorSummary: "A provider and model are required"
                )
            }
            return try await transition(
                run, to: .ready, lease: lease,
                event: "autonomous_run_ready", summary: "Run validation passed"
            )
        case .ready:
            return try await transition(
                run, to: .starting, lease: lease,
                event: "autonomous_run_starting", summary: "Run startup began"
            )
        case .starting:
            return try await transition(
                run, to: .running, lease: lease,
                event: "autonomous_run_running", summary: "Run execution started"
            )
        case .waitingProvider, .waitingResource, .retryWait:
            if let retryAt = run.retryAt,
               let retryDate = ISO8601.date(from: retryAt), retryDate > clock.now() {
                return nil
            }
            return try await transition(
                run, to: .recovering, lease: lease,
                event: "autonomous_run_recovery_started", summary: "Durable retry became ready"
            )
        case .failedRecoverable:
            return try await transition(
                run, to: .recovering, lease: lease,
                event: "autonomous_run_recovery_started", summary: "Recoverable failure entered recovery"
            )
        default:
            return nil
        }
    }

    private func invocationContext(for run: AutonomousRunRecord) async throws -> ToolInvocationContext {
        let owner: ProjectBindingOwner
        // Continuity recovery deliberately fences the predecessor binding before creating
        // a successor. Its already-persisted intent therefore runs under the durable run
        // binding; provider/tool work still requires the one accepted active session.
        if run.specification.work.pendingIntent?.kind == .continuity {
            owner = ProjectBindingOwner(kind: .autonomousRun, id: run.runID.description)
        } else if let sessionID = run.activeSessionID {
            owner = ProjectBindingOwner(kind: .providerSession, id: sessionID)
        } else {
            owner = ProjectBindingOwner(kind: .autonomousRun, id: run.runID.description)
        }
        return try await repository.invocationContext(
            for: owner,
            clientID: ClientID("autonomy:\(run.runID.description)")
        )
    }

    private func apply(
        _ outcome: ProjectRunStepOutcome,
        to run: AutonomousRunRecord,
        lease: RunLease
    ) async throws -> AutonomousRunRecord {
        switch outcome {
        case .continued(var work):
            work.pendingIntent = nil
            return try await transition(
                run, to: .running, lease: lease,
                event: "autonomous_run_step_completed", summary: "Run step completed", work: work
            )
        case .checkpointRequired(var work):
            work.pendingIntent = nil
            return try await transition(
                run, to: .checkpointing, lease: lease,
                event: "autonomous_checkpoint_required", summary: "A durable checkpoint is required", work: work
            )
        case .rolloverRequired(var work):
            work.pendingIntent = nil
            return try await transition(
                run, to: .rollingOver, lease: lease,
                event: "autonomous_rollover_required", summary: "A fresh-root rollover is required", work: work
            )
        case .completionRequested(let request):
            let requestJSON = try JSONSupport.canonicalJSON(["request": request])
            return try await transition(
                run, to: .validatingCompletion, lease: lease,
                event: "autonomous_completion_requested",
                summary: "Completion request entered deterministic validation",
                completionRequestJSON: requestJSON
            )
        case .completionRequestedWithWork(let request, var work):
            work.pendingIntent = nil
            let requestJSON = try JSONSupport.canonicalJSON(["request": request])
            return try await transition(
                run, to: .validatingCompletion, lease: lease,
                event: "autonomous_completion_requested",
                summary: "Completion request entered deterministic validation",
                work: work,
                completionRequestJSON: requestJSON
            )
        case .waitingProvider(let code, let summary):
            return try await waiting(run, state: .waitingProvider, code: code, summary: summary, lease: lease)
        case .waitingResource(let code, let summary):
            return try await waiting(run, state: .waitingResource, code: code, summary: summary, lease: lease)
        case .paused(let reason):
            return try await transition(
                run, to: .paused, lease: lease,
                event: "autonomous_run_paused", summary: reason
            )
        case .failedRecoverable(let code, let summary):
            return try await transition(
                run, to: .failedRecoverable, lease: lease,
                event: "autonomous_run_failed_recoverable", summary: summary,
                errorCode: code, errorSummary: summary
            )
        case .failedTerminal(let code, let summary):
            return try await transition(
                run, to: .failedTerminal, lease: lease,
                event: "autonomous_run_failed_terminal", summary: summary,
                errorCode: code, errorSummary: summary
            )
        case .cancelled:
            return try await transition(
                run, to: .cancelRequested, lease: lease,
                event: "autonomous_run_cancel_requested", summary: "Run cancellation was requested"
            )
        }
    }

    private func waiting(
        _ run: AutonomousRunRecord,
        state: AutonomousRunState,
        code: String,
        summary: String,
        lease: RunLease
    ) async throws -> AutonomousRunRecord {
        let seed = AutonomyRetryPolicy.deterministicSeed(
            runID: run.runID,
            attempt: Int(min(run.revision + 1, UInt64(Int.max)))
        )
        let delay = try retryPolicy.delay(attempt: 1, deterministicSeed: seed)
        return try await transition(
            run, to: state, lease: lease,
            event: state == .waitingProvider
                ? "autonomous_run_waiting_provider" : "autonomous_run_waiting_resource",
            summary: summary,
            errorCode: code,
            errorSummary: summary,
            retryAt: ISO8601.string(from: clock.now().addingTimeInterval(delay))
        )
    }

    private func validateCompletion(
        _ run: AutonomousRunRecord,
        lease: RunLease
    ) async throws -> AutonomousRunRecord {
        let protected = try await withLeaseRenewal(lease) { [completionValidator] in
            try await completionValidator.validate(run)
        }
        let receipt = protected.value
        if receipt.passed {
            return try await repository.completeAutonomousRun(
                runID: run.runID,
                lease: protected.lease,
                receipt: receipt
            )
        }
        var work = run.specification.work
        work.pendingIntent = nil
        work.metadata["completion_proof_sha256"] = receipt.proofSHA256
        return try await transition(
            run, to: .running, lease: protected.lease,
            event: "autonomous_completion_rejected",
            summary: "One or more deterministic completion gates failed",
            work: work,
            errorCode: AutonomyError.completionValidationFailed.code,
            errorSummary: "Completion gates did not all pass"
        )
    }

    private func withLeaseRenewal<Value: Sendable>(
        _ initialLease: RunLease,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> (value: Value, lease: RunLease) {
        let leaseState = RunLeaseState(initialLease)
        let repository = self.repository
        let policy = self.leasePolicy
        let sleeper = self.sleeper
        return try await withThrowingTaskGroup(of: LeaseProtectedEvent<Value>.self) { group in
            group.addTask {
                .value(try await operation())
            }
            group.addTask {
                while !Task.isCancelled {
                    try await sleeper.sleep(for: .seconds(policy.renewalInterval))
                    try Task.checkCancellation()
                    let current = await leaseState.current()
                    let renewed = try await repository.renewRunLease(current, policy: policy)
                    await leaseState.update(renewed)
                }
                throw CancellationError()
            }
            do {
                guard let first = try await group.next() else {
                    throw AutonomyError.leaseRequired
                }
                switch first {
                case .value(let value):
                    group.cancelAll()
                    do {
                        while try await group.next() != nil {}
                    } catch is CancellationError {
                        // Expected when the completed operation cancels its renewal owner.
                    }
                    return (value, await leaseState.current())
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func transition(
        _ run: AutonomousRunRecord,
        to state: AutonomousRunState,
        lease: RunLease,
        event: String,
        summary: String,
        work: AutonomousRunWork? = nil,
        completionRequestJSON: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        retryAt: String? = nil
    ) async throws -> AutonomousRunRecord {
        try await repository.transitionAutonomousRun(
            runID: run.runID,
            lease: lease,
            transition: AutonomousRunTransition(
                expectedState: run.state,
                expectedRevision: run.revision,
                nextState: state,
                eventType: event,
                eventSummary: summary,
                work: work,
                completionRequestJSON: completionRequestJSON,
                errorCode: errorCode,
                errorSummary: errorSummary,
                retryAt: retryAt
            )
        )
    }
}

private enum LeaseProtectedEvent<Value: Sendable>: Sendable {
    case value(Value)
}

private actor RunLeaseState {
    private var lease: RunLease

    init(_ lease: RunLease) { self.lease = lease }

    func current() -> RunLease { lease }
    func update(_ lease: RunLease) { self.lease = lease }
}
