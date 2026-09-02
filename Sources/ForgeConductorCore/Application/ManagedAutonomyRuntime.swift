// Manager-only composition for durable autonomous scheduling and provider execution.

import Foundation

public struct ManagedAutonomyRuntimeSnapshot: Sendable, Equatable {
    public let started: Bool
    public let startupReport: AutonomyStartupReport?
    public let supervisor: AutonomySupervisorSnapshot
}

public enum ManagedAutonomyControlAction: String, Codable, Sendable, CaseIterable {
    case pause
    case resume
    case cancel
    case retry
    case checkpoint
    case rollover
}

private enum OperatorContinuityMetadata {
    static let action = "operator_continuity_action"
    static let sessionID = "operator_continuity_session_id"
    static let requestID = "operator_continuity_request_id"
    static let operationID = "operator_continuity_operation_id"
    static let sourceObservationID = "operator_continuity_source_observation_id"
    static let observationID = "operator_continuity_observation_id"
    static let actionEpoch = "operator_continuity_action_epoch"
    static let requestedAt = "operator_continuity_requested_at"

    static let allKeys = [
        action,
        sessionID,
        requestID,
        operationID,
        sourceObservationID,
        observationID,
        actionEpoch,
        requestedAt,
    ]
}

private struct OperatorContinuityPlan: Sendable {
    let action: ContextBudgetAction
    let sessionID: String
    let requestID: UUID
    let operationID: UUID
    let sourceObservationID: UUID
    let observationID: UUID
    let actionEpoch: UInt64
    let requestedAt: String
}

/// Materializes an operator continuity request from the exact durable budget observation
/// named by the run transition before handing execution to the normal continuity worker.
/// Keeping the intent in run work first makes a manager crash between the transition and
/// budget-request commit recoverable without inventing provider usage or bypassing the V2
/// predecessor/successor state machine.
private struct OperatorManagedContinuityExecutor: ManagedRunContinuityExecuting, Sendable {
    let repository: ProjectControlPlaneRepository
    let delegate: any ManagedRunContinuityExecuting
    let clock: any Clock

    func executeContinuityStep(
        intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        guard let plan = try operatorPlan(from: run) else {
            return try await delegate.executeContinuityStep(
                intent: intent,
                run: run,
                context: context,
                lease: lease
            )
        }
        _ = try await materialize(plan, for: run)
        let outcome = try await delegate.executeContinuityStep(
            intent: intent,
            run: run,
            context: context,
            lease: lease
        )
        return Self.clearingOperatorIntent(from: outcome)
    }

    private func operatorPlan(from run: AutonomousRunRecord) throws -> OperatorContinuityPlan? {
        let metadata = run.specification.work.metadata
        guard let actionValue = metadata[OperatorContinuityMetadata.action] else {
            guard !OperatorContinuityMetadata.allKeys.contains(where: { metadata[$0] != nil }) else {
                throw AutonomyError.invalidRequest("operator continuity metadata is incomplete")
            }
            return nil
        }
        let action: ContextBudgetAction
        switch actionValue {
        case ContextBudgetAction.checkpoint.rawValue:
            action = .checkpoint
        case ContextBudgetAction.rollover.rawValue:
            action = .rollover
        default:
            throw AutonomyError.invalidRequest("operator continuity action is invalid")
        }
        guard let sessionID = metadata[OperatorContinuityMetadata.sessionID],
              let requestValue = metadata[OperatorContinuityMetadata.requestID],
              let requestID = UUID(uuidString: requestValue),
              let operationValue = metadata[OperatorContinuityMetadata.operationID],
              let operationID = UUID(uuidString: operationValue),
              let sourceValue = metadata[OperatorContinuityMetadata.sourceObservationID],
              let sourceObservationID = UUID(uuidString: sourceValue),
              let observationValue = metadata[OperatorContinuityMetadata.observationID],
              let observationID = UUID(uuidString: observationValue),
              let epochValue = metadata[OperatorContinuityMetadata.actionEpoch],
              let actionEpoch = UInt64(epochValue),
              let requestedAt = metadata[OperatorContinuityMetadata.requestedAt],
              ISO8601.date(from: requestedAt) != nil else {
            throw AutonomyError.invalidRequest("operator continuity metadata is incomplete")
        }
        return OperatorContinuityPlan(
            action: action,
            sessionID: sessionID,
            requestID: requestID,
            operationID: operationID,
            sourceObservationID: sourceObservationID,
            observationID: observationID,
            actionEpoch: actionEpoch,
            requestedAt: requestedAt
        )
    }

    private func materialize(
        _ plan: OperatorContinuityPlan,
        for run: AutonomousRunRecord
    ) async throws -> ContextBudgetActionRequest {
        let identity = ContextBudgetIdentity(
            runID: run.runID,
            projectID: run.projectID,
            projectGeneration: run.projectGeneration,
            sessionID: plan.sessionID
        )
        if let existing = try await repository.contextBudgetActionRequest(
            requestID: plan.requestID
        ) {
            guard existing.continuityOperationID == plan.operationID,
                  existing.identity == identity else {
                throw ContextBudgetError.invalidActionRequest
            }
            if existing.observationID == plan.observationID,
               existing.requestedAction == plan.action,
               existing.actionEpoch == plan.actionEpoch {
                return existing
            }
            guard existing.requestedAction.severity < plan.action.severity,
                  existing.actionEpoch < plan.actionEpoch else {
                throw ContextBudgetError.invalidActionRequest
            }
        }

        guard run.continuityMode == .managedAutonomous,
              run.state == .checkpointing || run.state == .rollingOver,
              run.activeSessionID == plan.sessionID,
              let session = try await repository.providerSession(plan.sessionID),
              session.runID == run.runID,
              session.projectID == run.projectID,
              session.projectGeneration == run.projectGeneration,
              session.providerID == run.providerID,
              session.adapterID == run.adapterID,
              session.modelKey == run.modelKey,
              session.status == .active,
              session.accepted else {
            throw AutonomyError.invalidRequest(
                "operator continuity requires the exact accepted active provider session"
            )
        }
        guard var state = try await repository.contextBudgetState(identity: identity),
              let source = state.latestObservation,
              source.observationID == plan.sourceObservationID,
              source.identity == identity,
              state.actionEpoch < UInt64(Int64.max),
              state.actionEpoch + 1 == plan.actionEpoch,
              state.observationCount < UInt64(Int64.max),
              state.revision < UInt64(Int64.max) else {
            throw ContextBudgetError.currentObservationRequired
        }
        if let conflicting = try await repository.contextBudgetActionRequest(identity: identity) {
            guard conflicting.requestID == plan.requestID,
                  conflicting.continuityOperationID == plan.operationID,
                  conflicting.requestedAction.severity < plan.action.severity,
                  conflicting.actionEpoch < plan.actionEpoch else {
                throw ContextBudgetError.invalidActionRequest
            }
        }

        let timestamp = ISO8601.string(from: clock.now())
        let observation = ContextBudgetObservation(
            observationID: plan.observationID,
            identity: identity,
            providerResponseID: source.providerResponseID,
            capacity: source.capacity,
            used: source.used,
            reserves: source.reserves,
            remaining: source.remaining,
            projectedNextTurn: source.projectedNextTurn,
            source: source.source,
            confidence: source.confidence,
            estimatorVersion: source.estimatorVersion,
            action: plan.action,
            triggerPoint: .managerRecovery,
            thresholds: source.thresholds,
            actionEpoch: plan.actionEpoch,
            createdAt: timestamp
        )
        state.latestObservation = observation
        state.action = plan.action
        state.lastRequestedAction = plan.action
        state.actionEpoch = plan.actionEpoch
        state.observationCount += 1
        state.revision += 1
        state.updatedAt = timestamp
        let receipt = try await repository.persistContextBudget(
            ContextBudgetPersistenceCommit(
                observation: observation,
                state: state,
                actionRequest: ContextBudgetActionRequestIntent(
                    requestID: plan.requestID,
                    continuityOperationID: plan.operationID,
                    identity: identity,
                    observationID: plan.observationID,
                    requestedAction: plan.action,
                    actionEpoch: plan.actionEpoch,
                    reason: "Operator requested \(plan.action.rawValue) from exact observation \(plan.sourceObservationID.uuidString.lowercased())"
                )
            )
        )
        guard let request = receipt.actionRequest,
              request.requestID == plan.requestID,
              request.continuityOperationID == plan.operationID,
              request.identity == identity,
              request.observationID == plan.observationID,
              request.requestedAction == plan.action,
              request.actionEpoch == plan.actionEpoch else {
            throw ContextBudgetError.invalidActionRequest
        }
        return request
    }

    private static func clearingOperatorIntent(
        from outcome: ProjectRunStepOutcome
    ) -> ProjectRunStepOutcome {
        switch outcome {
        case .continued(var work):
            clearOperatorIntent(from: &work)
            return .continued(work)
        case .checkpointRequired(var work):
            clearOperatorIntent(from: &work)
            return .checkpointRequired(work)
        case .rolloverRequired(var work):
            clearOperatorIntent(from: &work)
            return .rolloverRequired(work)
        case .completionRequestedWithWork(let request, var work):
            clearOperatorIntent(from: &work)
            return .completionRequestedWithWork(request, work)
        default:
            return outcome
        }
    }

    private static func clearOperatorIntent(from work: inout AutonomousRunWork) {
        for key in OperatorContinuityMetadata.allKeys {
            work.metadata.removeValue(forKey: key)
        }
    }
}

public struct EvidenceBoundCompletionValidator: RunCompletionValidating, Sendable {
    private let clock: any Clock

    public init(clock: any Clock = SystemClock()) {
        self.clock = clock
    }

    public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
        guard run.state == .validatingCompletion else {
            throw AutonomyError.completionValidationRequired
        }
        let results = run.specification.completionGates.map { gate in
            let key = "completion_gate.\(gate).proof_sha256"
            let proof = run.specification.work.metadata[key]
            let passed = proof.map { value in
                value.count == 64
                    && value.allSatisfy(\.isHexDigit)
                    && run.specification.work.evidenceReferences.contains(value)
            } ?? false
            return CompletionGateResult(
                gate: gate,
                passed: passed,
                summary: passed
                    ? "Deterministic evidence reference is present"
                    : "No manager-verified evidence reference is registered for this gate",
                evidenceReferences: proof.map { [$0] } ?? []
            )
        }
        return try CompletionValidationReceipt.make(
            runID: run.runID,
            expectedRevision: run.revision,
            results: results,
            validatedAt: ISO8601.string(from: clock.now())
        )
    }
}

public actor ManagedAutonomyRuntime {
    public typealias ContinuityFactory = @Sendable (
        _ runID: RunID
    ) throws -> any ManagedRunContinuityExecuting

    private let repository: ProjectControlPlaneRepository
    private let runtimeJobs: RuntimeJobSubsystem
    private let supervisor: AutonomySupervisor
    private let clock: any Clock
    private var started = false
    private var startupReport: AutonomyStartupReport?
    private var tickInProgress = false

    public init(
        app: ForgeApp,
        registry: HostAdapterRegistry = .shared,
        managerID: String? = nil,
        maximumConcurrentRuns: Int? = nil,
        continuityFactory: ContinuityFactory? = nil
    ) throws {
        let repository = app.projectContexts.repository
        let toolNames = app.tools.toolNames
        let catalog = try ToolDefinitionCatalog.production(toolNames: toolNames)
        let classifier = try ProductionToolReplayCatalog.classifier(
            productionToolNames: toolNames
        )
        let reconciler = ProductionToolInvocationReconciler(
            controlPlane: repository,
            runtimeJobs: app.runtimeJobs.repository,
            memory: app.projectMemory
        )
        let providerRoot = app.paths.managedProvidersDir
        let clock = app.clock
        let resolvedManagerID = managerID
            ?? "manager:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString.lowercased())"
        let concurrentRuns = maximumConcurrentRuns ?? Self.recommendedConcurrency()
        let resolvedContinuityFactory: ContinuityFactory = continuityFactory ?? { _ in
            ManagedContinuityWorker(
                repository: repository,
                memory: app.projectMemory,
                adapterResolver: { adapterID in
                    let storage = providerRoot.appendingPathComponent(
                        Self.storageComponent(adapterID),
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: storage,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let adapter = try registry.adapter(
                        identifier: adapterID,
                        storageDirectory: storage
                    )
                    guard let adapterV2 = adapter as? any SessionHostAdapterV2 else {
                        throw ContinuityRunError.hostCapabilityUnavailable
                    }
                    return adapterV2
                }
            )
        }

        self.repository = repository
        self.runtimeJobs = app.runtimeJobs
        self.clock = clock
        self.supervisor = try AutonomySupervisor(
            repository: repository,
            maximumConcurrentRuns: concurrentRuns,
            clock: clock
        ) { runID in
            let broker = ToolInvocationBroker(
                repository: repository,
                executor: app.tools,
                classifier: classifier,
                reconciler: reconciler
            )
            let budget = PersistedManagedRunBudgetEvaluator(
                repository: repository,
                clock: clock
            )
            let stepExecutor = try ManagedProjectRunStepExecutor(
                repository: repository,
                providerResolver: { adapterID in
                    let storage = providerRoot.appendingPathComponent(
                        Self.storageComponent(adapterID),
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: storage,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    guard let provider = try registry.managedProvider(
                        identifier: adapterID,
                        storageDirectory: storage
                    ) else {
                        throw ContinuityRunError.hostCapabilityUnavailable
                    }
                    return provider
                },
                toolDefinitionResolver: { allowedTools in
                    try catalog.providerToolDefinitions(allowedToolNames: allowedTools)
                },
                broker: broker,
                budget: budget,
                continuity: OperatorManagedContinuityExecutor(
                    repository: repository,
                    delegate: try resolvedContinuityFactory(runID),
                    clock: clock
                )
            )
            return try ProjectRunCoordinator(
                runID: runID,
                repository: repository,
                managerID: resolvedManagerID,
                stepExecutor: stepExecutor,
                completionValidator: EvidenceBoundCompletionValidator(clock: clock),
                clock: clock,
                maximumSteps: 16
            )
        }
    }

    @discardableResult
    public func start() async throws -> AutonomyStartupReport {
        guard !started else {
            if let startupReport { return startupReport }
            throw AutonomyError.invalidRequest("managed autonomy startup is already in progress")
        }
        try await runtimeJobs.start()
        do {
            let report = try await supervisor.recoverOnManagerStart()
            startupReport = report
            started = true
            return report
        } catch {
            await runtimeJobs.shutdown()
            throw error
        }
    }

    public func tick() async throws {
        guard started else { throw AutonomyError.shutdown }
        guard !tickInProgress else { return }
        tickInProgress = true
        defer { tickInProgress = false }
        try await supervisor.tick()
    }

    @discardableResult
    public func createRun(_ request: AutonomousRunRequest) async throws -> AutonomousRunRecord {
        guard started else { throw AutonomyError.shutdown }
        let reconciliation = try await repository.reconcileAutonomousRunStart(request)
        if reconciliation.requiresActivation, reconciliation.run.state.isExecutable {
            try await supervisor.activate(runID: reconciliation.run.runID)
        }
        return reconciliation.run
    }

    public func run(_ runID: RunID) async throws -> AutonomousRunRecord {
        guard let run = try await repository.autonomousRun(runID) else {
            throw AutonomyError.runNotFound(runID)
        }
        return run
    }

    @discardableResult
    public func controlRun(
        _ runID: RunID,
        action: ManagedAutonomyControlAction
    ) async throws -> AutonomousRunRecord {
        guard started else { throw AutonomyError.shutdown }
        if action == .checkpoint || action == .rollover {
            return try await requestOperatorContinuity(runID, action: action)
        }
        if action == .cancel {
            guard let candidate = try await repository.autonomousRun(runID) else {
                throw AutonomyError.runNotFound(runID)
            }
            guard !candidate.state.isTerminal else {
                throw AutonomyError.invalidRequest("terminal autonomous runs cannot be controlled")
            }
            _ = try await runtimeJobs.service.cancelJobs(runID: runID)
        }
        try await supervisor.quiesce(runID: runID)
        guard var run = try await repository.autonomousRun(runID) else {
            throw AutonomyError.runNotFound(runID)
        }
        guard !run.state.isTerminal else {
            throw AutonomyError.invalidRequest("terminal autonomous runs cannot be controlled")
        }

        if action == .pause, run.state == .paused { return run }
        if action == .cancel, run.state == .cancelRequested {
            try await supervisor.activate(runID: runID)
            return run
        }

        let nextState: AutonomousRunState
        var work = run.specification.work
        switch action {
        case .pause:
            work.metadata["paused_from_state"] = run.state.rawValue
            nextState = .paused
        case .resume:
            guard run.state == .paused else {
                throw AutonomyError.invalidRequest("only a paused run can be resumed")
            }
            let prior = work.metadata.removeValue(forKey: "paused_from_state")
            switch prior.flatMap(AutonomousRunState.init(rawValue:)) {
            case .created, .validating:
                nextState = .validating
            case .ready, .starting:
                nextState = .ready
            case .validatingCompletion:
                nextState = .validatingCompletion
            default:
                nextState = .recovering
            }
        case .cancel:
            nextState = .cancelRequested
        case .retry:
            guard [
                AutonomousRunState.waitingProvider, .waitingResource, .retryWait,
                .failedRecoverable, .blockedConfiguration,
            ].contains(run.state) else {
                throw AutonomyError.invalidRequest(
                    "only a waiting, blocked, or recoverable run can be retried"
                )
            }
            nextState = .recovering
        case .checkpoint, .rollover:
            preconditionFailure("operator continuity actions are handled before generic controls")
        }

        let lease = try await repository.acquireRunLease(
            runID: runID,
            ownerID: "manager-control:\(UUID().uuidString.lowercased())"
        )
        do {
            run = try await repository.transitionAutonomousRun(
                runID: runID,
                lease: lease,
                transition: AutonomousRunTransition(
                    expectedState: run.state,
                    expectedRevision: run.revision,
                    nextState: nextState,
                    eventType: "autonomous_run_\(action.rawValue)_requested",
                    eventSummary: "Operator requested autonomous run \(action.rawValue)",
                    work: work
                )
            )
            _ = try await repository.releaseRunLease(lease)
        } catch {
            _ = try? await repository.releaseRunLease(lease)
            throw error
        }
        if action != .pause {
            try await supervisor.activate(runID: runID)
        }
        return run
    }

    private func requestOperatorContinuity(
        _ runID: RunID,
        action: ManagedAutonomyControlAction
    ) async throws -> AutonomousRunRecord {
        guard let candidate = try await repository.autonomousRun(runID) else {
            throw AutonomyError.runNotFound(runID)
        }
        let targetState: AutonomousRunState = action == .checkpoint ? .checkpointing : .rollingOver
        if candidate.state == targetState,
           candidate.specification.work.metadata[OperatorContinuityMetadata.action]
            == action.rawValue,
           OperatorContinuityMetadata.allKeys.allSatisfy({
               candidate.specification.work.metadata[$0] != nil
           }) {
            try await supervisor.activate(runID: runID)
            return candidate
        }
        _ = try await operatorContinuityPlan(run: candidate, action: action)
        try await supervisor.quiesce(runID: runID)

        do {
            guard var run = try await repository.autonomousRun(runID) else {
                throw AutonomyError.runNotFound(runID)
            }
            let plan = try await operatorContinuityPlan(run: run, action: action)
            var work = run.specification.work
            work.metadata[OperatorContinuityMetadata.action] = plan.action.rawValue
            work.metadata[OperatorContinuityMetadata.sessionID] = plan.sessionID
            work.metadata[OperatorContinuityMetadata.requestID] =
                plan.requestID.uuidString.lowercased()
            work.metadata[OperatorContinuityMetadata.operationID] =
                plan.operationID.uuidString.lowercased()
            work.metadata[OperatorContinuityMetadata.sourceObservationID] =
                plan.sourceObservationID.uuidString.lowercased()
            work.metadata[OperatorContinuityMetadata.observationID] =
                plan.observationID.uuidString.lowercased()
            work.metadata[OperatorContinuityMetadata.actionEpoch] = String(plan.actionEpoch)
            work.metadata[OperatorContinuityMetadata.requestedAt] = plan.requestedAt

            let lease = try await repository.acquireRunLease(
                runID: runID,
                ownerID: "manager-control:\(UUID().uuidString.lowercased())"
            )
            do {
                run = try await repository.transitionAutonomousRun(
                    runID: runID,
                    lease: lease,
                    transition: AutonomousRunTransition(
                        expectedState: run.state,
                        expectedRevision: run.revision,
                        nextState: targetState,
                        eventType: "autonomous_run_operator_\(action.rawValue)_requested",
                        eventSummary: action == .checkpoint
                            ? "Operator requested a durable autonomous checkpoint"
                            : "Operator requested an early fresh-root rollover",
                        work: work
                    )
                )
                _ = try await repository.releaseRunLease(lease)
            } catch {
                _ = try? await repository.releaseRunLease(lease)
                throw error
            }
            try await supervisor.activate(runID: runID)
            return run
        } catch {
            if let current = try? await repository.autonomousRun(runID),
               current.state.isExecutable {
                try? await supervisor.activate(runID: runID)
            }
            throw error
        }
    }

    private func operatorContinuityPlan(
        run: AutonomousRunRecord,
        action: ManagedAutonomyControlAction
    ) async throws -> OperatorContinuityPlan {
        let requestedAction: ContextBudgetAction
        switch action {
        case .checkpoint:
            requestedAction = .checkpoint
        case .rollover:
            requestedAction = .rollover
        default:
            throw AutonomyError.invalidRequest("control action is not a continuity request")
        }
        guard run.state == .running,
              run.continuityMode == .managedAutonomous,
              run.specification.work.pendingIntent == nil,
              run.activeOperationID == nil,
              !run.continuationPending,
              let sessionID = run.activeSessionID,
              let session = try await repository.providerSession(sessionID),
              session.runID == run.runID,
              session.projectID == run.projectID,
              session.projectGeneration == run.projectGeneration,
              session.providerID == run.providerID,
              session.adapterID == run.adapterID,
              session.modelKey == run.modelKey,
              session.status == .active,
              session.accepted else {
            throw AutonomyError.invalidRequest(
                "operator continuity is allowed only for an idle running run with its exact accepted provider session"
            )
        }
        let identity = ContextBudgetIdentity(
            runID: run.runID,
            projectID: run.projectID,
            projectGeneration: run.projectGeneration,
            sessionID: sessionID
        )
        guard let state = try await repository.contextBudgetState(identity: identity),
              let source = state.latestObservation,
              source.identity == identity,
              state.actionEpoch < UInt64(Int64.max) else {
            throw ContextBudgetError.currentObservationRequired
        }
        let existing = try await repository.contextBudgetActionRequest(identity: identity)
        if let existing {
            guard existing.identity == identity else {
                throw ContextBudgetError.invalidActionRequest
            }
            if existing.isPending {
                guard existing.requestedAction.severity <= requestedAction.severity else {
                    throw AutonomyError.invalidRequest(
                        "a stronger continuity action is already pending for this provider session"
                    )
                }
                if existing.requestedAction == requestedAction {
                    return OperatorContinuityPlan(
                        action: requestedAction,
                        sessionID: sessionID,
                        requestID: existing.requestID,
                        operationID: existing.continuityOperationID,
                        sourceObservationID: existing.observationID,
                        observationID: existing.observationID,
                        actionEpoch: existing.actionEpoch,
                        requestedAt: existing.updatedAt
                    )
                }
            } else if existing.requestedAction.severity >= requestedAction.severity {
                throw AutonomyError.invalidRequest(
                    "this provider session has already fulfilled the requested continuity stage"
                )
            }
            guard state.actionEpoch < UInt64(Int64.max) else {
                throw ContextBudgetError.arithmeticOverflow
            }
            return OperatorContinuityPlan(
                action: requestedAction,
                sessionID: sessionID,
                requestID: existing.requestID,
                operationID: existing.continuityOperationID,
                sourceObservationID: source.observationID,
                observationID: UUID(),
                actionEpoch: state.actionEpoch + 1,
                requestedAt: ISO8601.string(from: clock.now())
            )
        }
        guard state.lastRequestedAction == nil, state.actionEpoch == 0 else {
            throw ContextBudgetError.invalidPersistedState
        }
        return OperatorContinuityPlan(
            action: requestedAction,
            sessionID: sessionID,
            requestID: UUID(),
            operationID: UUID(),
            sourceObservationID: source.observationID,
            observationID: UUID(),
            actionEpoch: 1,
            requestedAt: ISO8601.string(from: clock.now())
        )
    }

    public func snapshot() async -> ManagedAutonomyRuntimeSnapshot {
        ManagedAutonomyRuntimeSnapshot(
            started: started,
            startupReport: startupReport,
            supervisor: await supervisor.snapshot()
        )
    }

    public func shutdown() async {
        guard started || startupReport != nil else { return }
        started = false
        await supervisor.shutdown()
        await runtimeJobs.shutdown()
    }

    private static func recommendedConcurrency() -> Int {
        ResourcePolicy.current.nominalExecutionLimits.maximumActiveManagedGenerations
    }

    private static func storageComponent(_ adapterID: String) -> String {
        let safe = adapterID.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
            return allowed ? Character(String(scalar)) : "_"
        }
        return String(safe).prefix(128).description
    }
}
