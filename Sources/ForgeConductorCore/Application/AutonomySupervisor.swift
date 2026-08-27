// AutonomySupervisor.swift
// Owns bounded manager-side run coordinators and restart recovery independently of the GUI.

import Foundation

public protocol ProjectRunCoordinating: Sendable {
    var runID: RunID { get }
    func runActivation() async throws -> ProjectRunActivationResult
    func stop() async
}

extension ProjectRunCoordinator: ProjectRunCoordinating {}

public struct AutonomySupervisorSnapshot: Sendable, Equatable {
    public let acceptingRuns: Bool
    public let activeRunIDs: [RunID]
    public let deferredRunIDs: [RunID]
    public let recentResults: [ProjectRunActivationResult]
}

public actor AutonomySupervisor {
    public typealias CoordinatorFactory = @Sendable (RunID) throws -> any ProjectRunCoordinating

    public static let maximumRecoveredRuns = 1_024
    public static let maximumRetainedResults = 256

    private let repository: ProjectControlPlaneRepository
    private let coordinatorFactory: CoordinatorFactory
    private let maximumConcurrentRuns: Int
    private let clock: any Clock

    private var acceptingRuns = false
    private var coordinators: [RunID: any ProjectRunCoordinating] = [:]
    private var tasks: [RunID: Task<Void, Never>] = [:]
    private var deferred: [RunID] = []
    private var recentResults: [ProjectRunActivationResult] = []

    public init(
        repository: ProjectControlPlaneRepository,
        maximumConcurrentRuns: Int,
        clock: any Clock = SystemClock(),
        coordinatorFactory: @escaping CoordinatorFactory
    ) throws {
        guard (1...16).contains(maximumConcurrentRuns) else {
            throw AutonomyError.invalidRequest("active run limit must be between 1 and 16")
        }
        self.repository = repository
        self.maximumConcurrentRuns = maximumConcurrentRuns
        self.clock = clock
        self.coordinatorFactory = coordinatorFactory
    }

    /// Manager-start seam: call immediately after opening/migrating the control-plane
    /// database and before the dashboard begins accepting autonomous run commands.
    @discardableResult
    public func recoverOnManagerStart() async throws -> AutonomyStartupReport {
        guard tasks.isEmpty else {
            throw AutonomyError.invalidRequest("autonomy startup recovery is already active")
        }
        let released = try await repository.releaseExpiredRunLeases()
        _ = try await repository.recoverInterruptedContinuityCommands()
        let runs = try await repository.nonterminalAutonomousRuns(
            limit: Self.maximumRecoveredRuns
        )
        acceptingRuns = true
        deferred.removeAll(keepingCapacity: true)
        var eligible: [RunID] = []
        var stale: [RunID] = []
        for run in runs {
            do {
                _ = try await repository.validateAutonomousRunGeneration(run.runID)
                if isReadyForActivation(run) {
                    eligible.append(run.runID)
                }
            } catch let error as ProjectContextError where error.code == "stale_project_generation" {
                stale.append(run.runID)
            }
        }
        for runID in eligible.prefix(maximumConcurrentRuns) {
            try activateUnlocked(runID)
        }
        deferred = Array(eligible.dropFirst(maximumConcurrentRuns))
        return AutonomyStartupReport(
            releasedExpiredLeases: released,
            discoveredRuns: runs.count,
            activatedRuns: Array(eligible.prefix(maximumConcurrentRuns)),
            deferredRuns: deferred,
            staleGenerationRuns: stale
        )
    }

    /// Bounded watchdog seam. It never creates duplicate coordinators and only schedules
    /// runs whose durable retry time has arrived.
    public func tick() async throws {
        guard acceptingRuns else { throw AutonomyError.shutdown }
        let runs = try await repository.nonterminalAutonomousRuns(
            limit: Self.maximumRecoveredRuns
        )
        for run in runs where tasks[run.runID] == nil && !deferred.contains(run.runID) {
            guard isReadyForActivation(run) else { continue }
            deferred.append(run.runID)
        }
        try scheduleDeferredUnlocked()
    }

    public func activate(runID: RunID) async throws {
        guard acceptingRuns else { throw AutonomyError.shutdown }
        _ = try await repository.validateAutonomousRunGeneration(runID)
        guard tasks[runID] == nil else { return }
        if tasks.count < maximumConcurrentRuns {
            try activateUnlocked(runID)
        } else if !deferred.contains(runID) {
            guard deferred.count < Self.maximumRecoveredRuns else {
                throw AutonomyError.invalidRequest("deferred run queue reached its bound")
            }
            deferred.append(runID)
        }
    }

    public func snapshot() -> AutonomySupervisorSnapshot {
        AutonomySupervisorSnapshot(
            acceptingRuns: acceptingRuns,
            activeRunIDs: tasks.keys.sorted { $0.description < $1.description },
            deferredRunIDs: deferred,
            recentResults: recentResults
        )
    }

    /// Stops one in-memory coordinator without changing its durable run state. This is
    /// the serialization boundary used before an operator control transaction.
    public func quiesce(runID: RunID) async throws {
        deferred.removeAll { $0 == runID }
        guard let coordinator = coordinators[runID] else { return }
        await coordinator.stop()
        tasks[runID]?.cancel()
        for _ in 0..<400 {
            if tasks[runID] == nil { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw AutonomyError.invalidRequest(
            "autonomous run did not quiesce within the bounded control deadline"
        )
    }

    /// Stops accepting work, cancels every owned activation, and invokes each
    /// coordinator's bounded cancellation path. Durable nonterminal run state is retained.
    public func shutdown() async {
        acceptingRuns = false
        deferred.removeAll(keepingCapacity: false)
        let active = coordinators.values
        for coordinator in active { await coordinator.stop() }
        for task in tasks.values { task.cancel() }
        for _ in 0..<400 {
            if tasks.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        tasks.removeAll(keepingCapacity: false)
        coordinators.removeAll(keepingCapacity: false)
    }

    private func isReadyForActivation(_ run: AutonomousRunRecord) -> Bool {
        guard run.state.isExecutable else { return false }
        if [.waitingProvider, .waitingResource, .retryWait].contains(run.state),
           let retryAt = run.retryAt,
           let retryDate = ISO8601.date(from: retryAt), retryDate > clock.now() {
            return false
        }
        return true
    }

    private func activateUnlocked(_ runID: RunID) throws {
        guard tasks[runID] == nil else { return }
        let coordinator = try coordinatorFactory(runID)
        coordinators[runID] = coordinator
        tasks[runID] = Task { [self, coordinator] in
            let result: Result<ProjectRunActivationResult, Error>
            do {
                result = .success(try await coordinator.runActivation())
            } catch {
                result = .failure(error)
            }
            await self.activationFinished(runID: runID, result: result)
        }
    }

    private func activationFinished(
        runID: RunID,
        result: Result<ProjectRunActivationResult, Error>
    ) async {
        tasks.removeValue(forKey: runID)
        coordinators.removeValue(forKey: runID)
        if case .success(let value) = result {
            recentResults.append(value)
            if recentResults.count > Self.maximumRetainedResults {
                recentResults.removeFirst(recentResults.count - Self.maximumRetainedResults)
            }
        }
        guard acceptingRuns else { return }
        try? scheduleDeferredUnlocked()
    }

    private func scheduleDeferredUnlocked() throws {
        while acceptingRuns, tasks.count < maximumConcurrentRuns, !deferred.isEmpty {
            let runID = deferred[0]
            guard tasks[runID] == nil else {
                deferred.removeFirst()
                continue
            }
            try activateUnlocked(runID)
            deferred.removeFirst()
        }
    }
}
