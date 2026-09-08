// AutonomySupervisor.swift
// Owns bounded manager-side run coordinators and restart recovery independently of the GUI.

import Foundation

public protocol ProjectRunCoordinating: Sendable {
    var runID: RunID { get }
    func runActivation() async throws -> ProjectRunActivationResult
    func stop() async
}

extension ProjectRunCoordinator: ProjectRunCoordinating {}

/// Manager composition supplies metadata discovery and live task/policy admission.
/// This route owns no lease and cannot admit ordinary work through an ingress hold.
struct SourceBootstrapScheduling: Sendable {
    let discover: @Sendable (_ afterRowID: Int64?, _ limit: Int) async throws -> ContinuityBootstrapRecoveryPage
    let admit: @Sendable (ContinuityBootstrapRecoveryReference) async throws -> Bool
    let makeCoordinator: @Sendable (ContinuityBootstrapRecoveryReference) throws -> any ProjectRunCoordinating
}

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
    private let sourceBootstrap: SourceBootstrapScheduling?
    private let maximumConcurrentRuns: Int
    private let clock: any Clock

    private var acceptingRuns = false
    private var coordinators: [RunID: any ProjectRunCoordinating] = [:]
    private var tasks: [RunID: Task<Void, Never>] = [:]
    private enum DeferredActivation: Sendable, Equatable {
        case ordinary(RunID)
        case source(ContinuityBootstrapRecoveryReference)

        var runID: RunID {
            switch self { case .ordinary(let runID): runID; case .source(let reference): reference.runID }
        }
        var isSource: Bool {
            if case .source = self { return true }; return false
        }
    }
    private var deferred: [DeferredActivation] = []
    private var recentResults: [ProjectRunActivationResult] = []
    private var schedulingDeferred = false
    private var discovering = false
    private var sourceCursor: Int64?
    private var preferSource = true
    private var schedulingEpoch = UUID()
    static let sourceDiscoveryLimit = 16

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
        self.sourceBootstrap = nil
    }

    init(
        repository: ProjectControlPlaneRepository,
        maximumConcurrentRuns: Int,
        clock: any Clock = SystemClock(),
        sourceBootstrap: SourceBootstrapScheduling,
        coordinatorFactory: @escaping CoordinatorFactory
    ) throws {
        guard (1...16).contains(maximumConcurrentRuns) else {
            throw AutonomyError.invalidRequest("active run limit must be between 1 and 16")
        }
        self.repository = repository
        self.maximumConcurrentRuns = maximumConcurrentRuns
        self.clock = clock
        self.coordinatorFactory = coordinatorFactory
        self.sourceBootstrap = sourceBootstrap
    }

    /// Manager-start seam: call immediately after opening/migrating the control-plane
    /// database and before the dashboard begins accepting autonomous run commands.
    @discardableResult
    public func recoverOnManagerStart() async throws -> AutonomyStartupReport {
        guard tasks.isEmpty, !discovering else {
            throw AutonomyError.invalidRequest("autonomy startup recovery is already active")
        }
        discovering = true
        defer { discovering = false }
        let epoch = schedulingEpoch
        let released = try await repository.releaseExpiredRunLeases()
        _ = try await repository.recoverInterruptedContinuityCommands()
        let runs = try await repository.nonterminalAutonomousRuns(
            limit: Self.maximumRecoveredRuns
        )
        guard epoch == schedulingEpoch else { throw AutonomyError.shutdown }
        acceptingRuns = true
        deferred.removeAll(keepingCapacity: true)
        sourceCursor = nil
        preferSource = true
        var stale: [RunID] = []
        for run in runs {
            do {
                if let current = try await activationAdmission(run.runID), isReadyForActivation(current) {
                    guard acceptingRuns, epoch == schedulingEpoch else { throw AutonomyError.shutdown }
                    enqueue(.ordinary(current.runID))
                }
            } catch let error as ProjectContextError where error.code == "stale_project_generation" {
                stale.append(run.runID)
            }
        }
        try await discoverSourceBootstrap(epoch: epoch)
        guard acceptingRuns, epoch == schedulingEpoch else { throw AutonomyError.shutdown }
        let activated = try await scheduleDeferredUnlocked()
        guard acceptingRuns else { throw AutonomyError.shutdown }
        return AutonomyStartupReport(
            releasedExpiredLeases: released,
            discoveredRuns: runs.count,
            activatedRuns: activated,
            deferredRuns: deferred.map(\.runID),
            staleGenerationRuns: stale
        )
    }

    /// Bounded watchdog seam. It never creates duplicate coordinators and only schedules
    /// runs whose durable retry time has arrived.
    public func tick() async throws {
        guard acceptingRuns else { throw AutonomyError.shutdown }
        guard !discovering else { return }
        discovering = true
        defer { discovering = false }
        let epoch = schedulingEpoch
        let runs = try await repository.nonterminalAutonomousRuns(
            limit: Self.maximumRecoveredRuns
        )
        for run in runs where tasks[run.runID] == nil && !isDeferred(run.runID) {
            guard isReadyForActivation(run) else { continue }
            guard let current = try await activationAdmission(run.runID), isReadyForActivation(current),
                  tasks[run.runID] == nil, !isDeferred(run.runID) else { continue }
            guard acceptingRuns, epoch == schedulingEpoch else { return }
            enqueue(.ordinary(run.runID))
        }
        try await discoverSourceBootstrap(epoch: epoch)
        guard acceptingRuns, epoch == schedulingEpoch else { return }
        _ = try await scheduleDeferredUnlocked()
    }

    public func activate(runID: RunID) async throws {
        guard acceptingRuns else { throw AutonomyError.shutdown }
        let epoch = schedulingEpoch
        guard let run = try await activationAdmission(runID) else {
            throw AutonomyError.bootstrapRequired(runID)
        }
        guard run.state != .awaitingBootstrap else { throw AutonomyError.bootstrapRequired(runID) }
        guard acceptingRuns, epoch == schedulingEpoch else { throw AutonomyError.shutdown }
        guard tasks[runID] == nil else { return }
        if tasks.count < maximumConcurrentRuns {
            try activateUnlocked(.ordinary(runID))
        } else if !isDeferred(runID) {
            guard deferred.count < Self.maximumRecoveredRuns else {
                throw AutonomyError.invalidRequest("deferred run queue reached its bound")
            }
            deferred.append(.ordinary(runID))
        }
    }

    public func snapshot() -> AutonomySupervisorSnapshot {
        AutonomySupervisorSnapshot(
            acceptingRuns: acceptingRuns,
            activeRunIDs: tasks.keys.sorted { $0.description < $1.description },
            deferredRunIDs: deferred.map(\.runID),
            recentResults: recentResults
        )
    }

    /// Stops one in-memory coordinator without changing its durable run state. This is
    /// the serialization boundary used before an operator control transaction.
    public func quiesce(runID: RunID) async throws {
        schedulingEpoch = UUID()
        deferred.removeAll { $0.runID == runID }
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
        schedulingEpoch = UUID()
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

    private func activateUnlocked(_ activation: DeferredActivation) throws {
        let runID = activation.runID
        guard tasks[runID] == nil else { return }
        let coordinator: any ProjectRunCoordinating
        switch activation {
        case .ordinary: coordinator = try coordinatorFactory(runID)
        case .source(let reference):
            guard let sourceBootstrap else { throw AutonomyError.bootstrapRequired(runID) }
            coordinator = try sourceBootstrap.makeCoordinator(reference)
        }
        guard coordinator.runID == runID else { throw AutonomyError.invalidRequest("coordinator belongs to another run") }
        preferSource = !activation.isSource
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
        _ = try? await scheduleDeferredUnlocked()
    }

    /// Re-read typed admission immediately before constructing either coordinator.
    /// A deferred run may have acquired a hold or lost source authority while queued.
    private func scheduleDeferredUnlocked() async throws -> [RunID] {
        guard !schedulingDeferred else { return [] }
        schedulingDeferred = true
        defer { schedulingDeferred = false }
        let epoch = schedulingEpoch
        var activated: [RunID] = []
        while acceptingRuns, tasks.count < maximumConcurrentRuns, !deferred.isEmpty {
            let index = deferred.firstIndex(where: { $0.isSource == preferSource }) ?? 0
            let activation = deferred[index]
            let runID = activation.runID
            guard tasks[runID] == nil else {
                deferred.removeAll { $0.runID == runID }
                continue
            }
            let admitted: Bool
            switch activation {
            case .ordinary:
                if let run = try await activationAdmission(runID) { admitted = isReadyForActivation(run) }
                else { admitted = false }
            case .source(let reference):
                do { admitted = try await sourceBootstrap?.admit(reference) ?? false }
                catch is CancellationError { throw CancellationError() }
                catch { admitted = false }
            }
            guard admitted else {
                deferred.removeAll { $0 == activation }
                continue
            }
            guard acceptingRuns, epoch == schedulingEpoch, tasks.count < maximumConcurrentRuns else { break }
            guard deferred.contains(activation) else { continue }
            if tasks[runID] != nil {
                deferred.removeAll { $0.runID == runID }
                continue
            }
            do { try activateUnlocked(activation) }
            catch where activation.isSource {
                deferred.removeAll { $0 == activation }
                continue
            }
            activated.append(runID)
            deferred.removeAll { $0.runID == runID }
        }
        return activated
    }

    private func isDeferred(_ runID: RunID) -> Bool { deferred.contains { $0.runID == runID } }

    private func enqueue(_ activation: DeferredActivation) {
        guard tasks[activation.runID] == nil, !isDeferred(activation.runID) else { return }
        if deferred.count == Self.maximumRecoveredRuns {
            // Replacing a metadata hint does not discard durable work. Reserve a
            // turn for a newly discovered kind even when the other filled the queue.
            guard !deferred.contains(where: { $0.isSource == activation.isSource }),
                  let index = deferred.lastIndex(where: { $0.isSource != activation.isSource }) else { return }
            deferred.remove(at: index)
        }
        deferred.append(activation)
    }

    private func discoverSourceBootstrap(epoch: UUID) async throws {
        guard let sourceBootstrap, acceptingRuns, epoch == schedulingEpoch else { return }
        let page: ContinuityBootstrapRecoveryPage
        do { page = try await sourceBootstrap.discover(sourceCursor, Self.sourceDiscoveryLimit) }
        catch is CancellationError { throw CancellationError() }
        catch { return } // A source metadata failure cannot stop ordinary recovery.
        guard acceptingRuns, epoch == schedulingEpoch else { return }
        sourceCursor = page.nextRowID
        for reference in page.references.prefix(Self.sourceDiscoveryLimit) {
            guard tasks[reference.runID] == nil, !isDeferred(reference.runID) else { continue }
            do {
                guard try await sourceBootstrap.admit(reference) else { continue }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
            guard acceptingRuns, epoch == schedulingEpoch else { return }
            enqueue(.source(reference))
        }
    }

    private func activationAdmission(_ runID: RunID) async throws -> AutonomousRunRecord? {
        let current = try await repository.validateAutonomousRunGeneration(runID)
        // Cancellation only stops owned work; it must remain available while held.
        if current.state == .cancelRequested { return current }
        if current.state.isTerminal { return current }
        do {
            return try await repository.validateAutonomousRunExecutionAdmission(runID)
        } catch AutonomyError.bootstrapRequired {
            return nil
        }
    }
}
