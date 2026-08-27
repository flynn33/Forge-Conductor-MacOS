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
                continuity: try resolvedContinuityFactory(runID)
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
