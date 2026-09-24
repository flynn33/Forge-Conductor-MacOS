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

public struct CompletionGateJob: Sendable {
    public let run: AutonomousRunRecord
    public let jobID: UUID
    public let nonce: UUID
    public let startedAt: String

    init(run: AutonomousRunRecord, clock: any Clock) {
        self.run = run
        jobID = UUID()
        nonce = UUID()
        startedAt = ISO8601.string(from: clock.now())
    }
}

public struct CompletionGateValidator: Sendable {
    public let gate: String
    public let version: UInt64
    private let operation: @Sendable (CompletionGateJob) async throws -> CompletionGateResult

    public init(
        gate: String,
        version: UInt64 = 1,
        operation: @escaping @Sendable (AutonomousRunRecord) async throws -> CompletionGateResult
    ) {
        self.gate = gate
        self.version = version
        self.operation = { try await operation($0.run) }
    }

    public init(
        gate: String,
        version: UInt64,
        jobOperation: @escaping @Sendable (CompletionGateJob) async throws -> CompletionGateResult
    ) {
        self.gate = gate
        self.version = version
        self.operation = jobOperation
    }

    public func evaluate(_ run: AutonomousRunRecord) async throws -> CompletionGateResult {
        try await operation(CompletionGateJob(run: run, clock: SystemClock()))
    }

    func evaluate(_ job: CompletionGateJob) async throws -> CompletionGateResult {
        try await operation(job)
    }
}

/// Validators are supplied by manager-owned completion checks. This type is not
/// decodable and has no model-tool registration surface. Missing validators
/// fail closed and never select a provenance-only fallback.
public struct GateValidatorRegistry: RunCompletionValidating, Sendable {
    private let validators: [String: CompletionGateValidator]
    private let clock: any Clock
    private let acceptancePolicy: CompletionGateAcceptancePolicy?

    public init(
        validators: [CompletionGateValidator],
        clock: any Clock = SystemClock(),
        acceptancePolicy: CompletionGateAcceptancePolicy? = nil
    ) throws {
        guard validators.count <= 256,
              Set(validators.map(\.gate)).count == validators.count,
              validators.allSatisfy({ !$0.gate.isEmpty && $0.gate.utf8.count <= 512 && $0.version > 0 }) else {
            throw AutonomyError.invalidRequest("completion validators must be unique and bounded")
        }
        self.validators = Dictionary(uniqueKeysWithValues: validators.map { ($0.gate, $0) })
        self.clock = clock
        self.acceptancePolicy = acceptancePolicy
    }

    public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
        guard run.state == .validatingCompletion else {
            throw AutonomyError.completionValidationRequired
        }
        guard !run.specification.completionGates.isEmpty,
              run.specification.completionGates.count <= 256,
              Set(run.specification.completionGates).count == run.specification.completionGates.count else {
            throw AutonomyError.completionValidationFailed
        }
        var results: [CompletionGateResult] = []
        results.reserveCapacity(run.specification.completionGates.count)
        for gate in run.specification.completionGates {
            guard let validator = validators[gate] else {
                results.append(CompletionGateResult(
                    gate: gate,
                    passed: false,
                    summary: "No deterministic validator is registered for this gate",
                    blocker: .unregisteredValidator
                ))
                continue
            }
            if let acceptancePolicy, !acceptancePolicy.isConfigured(for: gate) {
                results.append(CompletionGateResult(
                    gate: gate, passed: false,
                    summary: "Required acceptance cases have no installed native test binding",
                    blocker: .unregisteredValidator
                ))
                continue
            }
            let job = CompletionGateJob(run: run, clock: clock)
            let result = try await validator.evaluate(job)
            guard result.gate == gate else {
                throw AutonomyError.invalidRequest("completion validator returned the wrong gate identity")
            }
            guard result.summary.utf8.count <= 2_048,
                  result.evidenceReferences.count <= 256,
                  result.evidenceReferences.allSatisfy({ $0.utf8.count <= 2_048 }) else {
                throw AutonomyError.invalidRequest("completion result exceeds its durable bound")
            }
            // The handler cannot select the invocation's run, attempt, or version.
            // A decoded receipt still needs the repository's process-local approval.
            let acceptancePassed = acceptancePolicy?.accepts(result, version: validator.version) ?? true
            results.append(CompletionGateResult(
                gate: gate,
                passed: result.passed && result.blocker == nil
                    && acceptancePassed,
                summary: !acceptancePassed
                    ? "Required current-policy native acceptance evidence is missing or non-passing" : result.summary,
                evidenceReferences: result.evidenceReferences,
                nativeEvidence: result.nativeEvidence,
                invocation: try CompletionGateInvocation(
                    run: run, gateVersion: validator.version,
                    jobID: job.jobID, nonce: job.nonce,
                    startedAt: job.startedAt, finishedAt: ISO8601.string(from: clock.now())
                ),
                blocker: result.blocker
            ))
        }
        return try CompletionValidationReceipt.make(
            runID: run.runID,
            expectedRevision: run.revision,
            results: results,
            validatedAt: ISO8601.string(from: clock.now())
        )
    }
}

/// A native composition rule for separately authorized qualification packages.
/// Case bindings are installed handler policy, never model completion metadata.
/// The correction requires all 24 cases, including live-provider and desktop
/// assertions; a binding names a test, it does not claim that the test exists or ran.
public struct CompletionGateAcceptancePolicy: Sendable {
    public static let correction001Revision = "CLU-CORRECTION-001:0aa7cb3529ed1c68a6ec0bc0becdc58f5e17ed876593d5346a3aa4e6af01d779"
    public static let correction001Cases: [String: Set<String>] = [
        "G01": ["CLU-C01-23"],
        "G04": ["CLU-C01-01", "CLU-C01-02", "CLU-C01-03", "CLU-C01-04", "CLU-C01-05",
                "CLU-C01-07", "CLU-C01-08", "CLU-C01-09", "CLU-C01-10", "CLU-C01-11"],
        "G05": ["CLU-C01-06", "CLU-C01-16"],
        "G06": ["CLU-C01-12"], "G07": ["CLU-C01-13"], "G08": ["CLU-C01-14"],
        "G09": ["CLU-C01-15"], "G10": ["CLU-C01-17", "CLU-C01-21"],
        "G12": ["CLU-C01-18", "CLU-C01-19", "CLU-C01-20"],
        "G13": ["CLU-C01-22"], "G14": ["CLU-C01-24"],
    ]
    private let caseBindings: [String: String]

    public static func correction001(caseBindings: [String: String]) throws -> Self {
        let known = Set(correction001Cases.values.flatMap { $0 })
        guard Set(caseBindings.keys).isSubset(of: known),
              Set(caseBindings.values).count == caseBindings.count,
              caseBindings.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else {
            throw AutonomyError.invalidRequest("correction acceptance bindings must be known, unique native case identities")
        }
        return Self(caseBindings: caseBindings)
    }

    func isConfigured(for gate: String) -> Bool {
        guard let required = Self.correction001Cases[gate] else { return true }
        return required.allSatisfy { caseBindings[$0] != nil }
    }

    func accepts(_ result: CompletionGateResult, version: UInt64) -> Bool {
        guard let required = Self.correction001Cases[result.gate] else { return true }
        guard isConfigured(for: result.gate), version >= 2,
              let evidence = result.nativeEvidence,
              evidence.inputs.policyRevision == Self.correction001Revision,
              evidence.exitCode == 0, evidence.terminationSignal == nil,
              !evidence.timedOut, !evidence.outputTruncated,
              evidence.testReport.passed, evidence.testReport.failures.isEmpty else { return false }
        let cases = evidence.testReport.cases
        let identifiers = Set(cases.map(\.identifier))
        return cases.allSatisfy { $0.result == "Passed" }
            && identifiers.count == cases.count
            && required.allSatisfy { caseBindings[$0].map(identifiers.contains) == true }
    }
}

/// Compatibility entrypoint for callers that install native deterministic handlers.
public struct DeterministicCompletionValidator: RunCompletionValidating, Sendable {
    private let registry: GateValidatorRegistry

    public init(validators: [CompletionGateValidator], clock: any Clock = SystemClock()) throws {
        guard !validators.isEmpty else {
            throw AutonomyError.invalidRequest("completion validators must be unique and bounded")
        }
        registry = try GateValidatorRegistry(validators: validators, clock: clock)
    }

    public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
        try await registry.validate(run)
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
    private let observationRecorder: (any StjornarvaldObservationRecording)?
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
        observationRecorder: (any StjornarvaldObservationRecording)? = nil,
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
        self.observationRecorder = observationRecorder
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
            run = try await repository.validateAutonomousRunGeneration(runID)
            if run.state != .cancelRequested {
                run = try await repository.validateAutonomousRunExecutionAdmission(runID)
            }
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
                let failurePolicy = try run.specification.failurePolicy.validated()
                let priorRetryCount = Int(run.specification.work.metadata["failure_retry_count"] ?? "0") ?? 0
                let nextRetryCount = priorRetryCount + 1
                let providerFailure = error as? any ManagedProviderFailure
                let waitsForConfiguration = providerFailure?
                    .managedProviderFailureDisposition == .blockedConfiguration
                let priorConfigurationWaitCount = Int(
                    run.specification.work.metadata[
                        "provider_configuration_wait_count"
                    ] ?? "0"
                ) ?? 0
                if failurePolicy.behavior == .pauseForReview {
                    run = try await transition(
                        run, to: .paused, lease: lease,
                        event: "autonomous_run_paused_after_failure",
                        summary: failurePolicy.customInstructions ?? "Task paused for review after a failure",
                        errorCode: "run_step_failed",
                        errorSummary: String(error.localizedDescription.prefix(2_048))
                    )
                    break
                }
                if failurePolicy.behavior == .stopTask {
                    run = try await transition(
                        run, to: .failedTerminal, lease: lease,
                        event: "autonomous_run_stopped_after_failure",
                        summary: failurePolicy.customInstructions ?? "Task stopped after a failure",
                        errorCode: "run_step_failed",
                        errorSummary: String(error.localizedDescription.prefix(2_048))
                    )
                    break
                }
                if !waitsForConfiguration,
                   nextRetryCount > failurePolicy.maximumRetries {
                    run = try await transition(
                        run, to: .paused, lease: lease,
                        event: "autonomous_run_retry_limit_reached",
                        summary: "Automatic retry limit reached; review is required",
                        errorCode: "retry_limit_reached",
                        errorSummary: String(error.localizedDescription.prefix(2_048))
                    )
                    break
                }
                if waitsForConfiguration,
                   priorConfigurationWaitCount >= retryPolicy.maximumAttempts {
                    var pausedWork = run.specification.work
                    pausedWork.metadata["provider_configuration_auto_resume"] = "pending"
                    pausedWork.nextAction = "Open Provider and choose Connect and Check. Forge retained the exact operation and will resume it automatically after the provider passes its contract check."
                    run = try await transition(
                        run, to: .paused, lease: lease,
                        event: "autonomous_run_provider_recovery_deadline_reached",
                        summary: "Automatic provider recovery reached its bounded deadline",
                        work: pausedWork,
                        errorCode: providerFailure?.managedProviderFailureCode,
                        errorSummary: String(error.localizedDescription.prefix(2_048))
                    )
                    break
                }
                var retryWork = run.specification.work
                if waitsForConfiguration {
                    retryWork.metadata["provider_configuration_wait_count"] = String(
                        priorConfigurationWaitCount + 1
                    )
                } else {
                    retryWork.metadata["failure_retry_count"] = String(nextRetryCount)
                }
                let attempt = max(
                    1,
                    waitsForConfiguration
                        ? priorConfigurationWaitCount + 1
                        : nextRetryCount
                )
                let seed = AutonomyRetryPolicy.deterministicSeed(runID: runID, attempt: attempt)
                let policyDelay = try retryPolicy.delay(
                    attempt: min(attempt, retryPolicy.maximumAttempts),
                    deterministicSeed: seed
                )
                let summary = String(error.localizedDescription.prefix(2_048))
                if let failure = providerFailure {
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
                            work: retryWork,
                            errorCode: failure.managedProviderFailureCode,
                            errorSummary: summary,
                            retryAt: ISO8601.string(from: clock.now().addingTimeInterval(delay))
                        )
                    case .blockedConfiguration:
                        // A provider setting may require a user action in the host,
                        // but the retained run does not require a second manual
                        // Retry in Forge. Keep it in the scheduler's bounded
                        // provider-wait path so Connect and Check can repair the
                        // dependency and the exact pending turn resumes.
                        let delay = min(
                            retryPolicy.totalDeadline,
                            max(retryPolicy.baseDelay, min(retryPolicy.maximumDelay, policyDelay))
                        )
                        run = try await transition(
                            run, to: .waitingProvider, lease: lease,
                            event: "autonomous_run_waiting_provider_configuration",
                            summary: "Managed provider configuration is being repaired",
                            work: retryWork,
                            errorCode: failure.managedProviderFailureCode,
                            errorSummary: summary,
                            retryAt: ISO8601.string(
                                from: clock.now().addingTimeInterval(delay)
                            )
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
                            work: retryWork,
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
                        work: retryWork,
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
                var work = run.specification.work
                work.metadata["provider_configuration_auto_resume"] = "pending"
                work.metadata["provider_configuration_wait_count"] = "1"
                work.nextAction = "Open Provider and choose Connect and Check. Forge will retain this task and resume it automatically after provider and model discovery succeeds."
                let seed = AutonomyRetryPolicy.deterministicSeed(
                    runID: run.runID,
                    attempt: 1
                )
                let delay = try retryPolicy.delay(attempt: 1, deterministicSeed: seed)
                return try await transition(
                    run, to: .waitingProvider, lease: lease,
                    event: "autonomous_run_waiting_provider_configuration",
                    summary: "Provider and model discovery are required before this task can start",
                    work: work,
                    errorCode: "provider_configuration_missing",
                    errorSummary: "Open Provider and choose Connect and Check; Forge will resume this task automatically when discovery succeeds.",
                    retryAt: ISO8601.string(
                        from: clock.now().addingTimeInterval(delay)
                    )
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
            let transitioned = try await transition(
                run, to: .validatingCompletion, lease: lease,
                event: "autonomous_completion_requested",
                summary: "Completion request entered deterministic validation",
                completionRequestJSON: requestJSON
            )
            recordCompletionClaim(run: transitioned, requestJSON: requestJSON)
            return transitioned
        case .completionRequestedWithWork(let request, var work):
            work.pendingIntent = nil
            let requestJSON = try JSONSupport.canonicalJSON(["request": request])
            let transitioned = try await transition(
                run, to: .validatingCompletion, lease: lease,
                event: "autonomous_completion_requested",
                summary: "Completion request entered deterministic validation",
                work: work,
                completionRequestJSON: requestJSON
            )
            recordCompletionClaim(run: transitioned, requestJSON: requestJSON)
            return transitioned
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

    private func recordCompletionClaim(
        run: AutonomousRunRecord,
        requestJSON: String
    ) {
        observationRecorder?.record(
            StjornarvaldProductObservationFactory.completionClaim(
                run: run,
                requestSHA256: JSONSupport.sha256Hex(requestJSON),
                observedAt: clock.now()
            )
        )
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
            try await repository.recordTrustedCompletionValidation(receipt, for: run, lease: protected.lease)
            return try await repository.completeAutonomousRun(
                runID: run.runID,
                lease: protected.lease,
                receipt: receipt
            )
        }
        var work = run.specification.work
        work.pendingIntent = nil
        work.metadata["completion_proof_sha256"] = receipt.proofSHA256
        let failureSummary = Self.completionFailureSummary(receipt)
        work.nextAction = failureSummary
        // A new model completion claim is not new evidence. Persist the identity
        // of the actual validation results so restarts cannot reset a spin loop.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let evidenceResults = receipt.results.map {
            [$0.gate, $0.passed ? "passed" : "failed", $0.summary, $0.blocker?.rawValue ?? ""]
                + $0.evidenceReferences.sorted()
        }
        let evidenceIdentity = JSONSupport.sha256Hex(String(
            decoding: try encoder.encode(evidenceResults), as: UTF8.self
        ))
        let priorCount = min(max(Int(work.metadata["completion_no_progress_count"] ?? "0") ?? 0, 0),
                             AutonomousFailurePolicy.maximumRetryLimit + 1)
        let attempts = work.metadata["completion_evidence_identity"] == evidenceIdentity
            ? priorCount + 1 : 1
        work.metadata["completion_evidence_identity"] = evidenceIdentity
        work.metadata["completion_no_progress_count"] = String(attempts)
        let policy = try run.specification.failurePolicy.validated()
        let retryLimit = policy.behavior == .retryAutomatically ? policy.maximumRetries : 0
        if attempts > retryLimit {
            let recovery = policy.behavior == .stopTask
                ? "The task stopped according to its failure policy. Start a new task after correcting instruction delivery or the named evidence."
                : "Resume after correcting instruction delivery or the named evidence; the saved task is preserved."
            work.nextAction = "No new completion evidence was produced after \(attempts) attempts. \(failureSummary) \(recovery)"
            return try await transition(
                run, to: policy.behavior == .stopTask ? .failedTerminal : .paused,
                lease: protected.lease,
                event: "autonomous_completion_no_progress",
                summary: "Stopped repeated completion requests without new evidence",
                work: work,
                errorCode: AutonomyError.completionValidationFailed.code,
                errorSummary: work.nextAction
            )
        }
        return try await transition(
            run, to: .running, lease: protected.lease,
            event: "autonomous_completion_rejected",
            summary: failureSummary,
            work: work,
            errorCode: AutonomyError.completionValidationFailed.code,
            errorSummary: failureSummary
        )
    }

    static func completionFailureSummary(
        _ receipt: CompletionValidationReceipt
    ) -> String {
        let failures = receipt.results.filter { !$0.passed }
        guard !failures.isEmpty else {
            return "Completion checks did not produce a passing receipt."
        }
        var seenSummaries = Set<String>()
        let distinct = failures.filter { seenSummaries.insert($0.summary).inserted }
        let details = distinct.prefix(4).map { result in
            "\(result.gate): \(result.summary)"
        }.joined(separator: "; ")
        let remainder = distinct.count > 4
            ? "; plus \(distinct.count - 4) more distinct failure(s)" : ""
        let unbounded = "Completion checks need attention — \(details)\(remainder)"
        var bounded = ""
        var byteCount = 0
        for character in unbounded {
            let width = String(character).utf8.count
            guard byteCount + width <= 2_048 else { break }
            bounded.append(character)
            byteCount += width
        }
        return bounded
    }

    private func withLeaseRenewal<Value: Sendable>(
        _ initialLease: RunLease,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> (value: Value, lease: RunLease) {
        try await RunLeaseProtection.withRenewal(initialLease, repository: repository,
            policy: leasePolicy, sleeper: sleeper, operation: operation)
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
