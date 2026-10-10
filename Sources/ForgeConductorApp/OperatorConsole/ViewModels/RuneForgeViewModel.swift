// RuneForgeViewModel.swift
// Owns the bounded, cached presentation state for the Rune Forge operator surface.

import Foundation
import ForgeConductorCore

protocol RuneForgeManagerClientProtocol: Sendable {
    func runeForgeProjectIDs() async throws -> [String]
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot
    func runeForgeSnapshot(
        projectID: String?,
        projectGeneration: UInt64?
    ) async throws -> StjornarvaldManagerSnapshot
    func addRuneForgeSource(path: String, requestID: UUID) async throws -> DevelopmentPolicySource
    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource
    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource
    func reorderRuneForgeSources(
        sourceIDs: [PolicySourceID]
    ) async throws -> [DevelopmentPolicySource]
    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage
    func scheduleRuneForgeScan(requestID: UUID, reason: String) async throws -> StjornarvaldScanReceipt
    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt
}

extension RuneForgeManagerClientProtocol {
    func runeForgeProjectIDs() async throws -> [String] { [] }

    func runeForgeSnapshot(
        projectID: String?,
        projectGeneration: UInt64?
    ) async throws -> StjornarvaldManagerSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Project-scoped policy monitoring is unavailable from this manager client."
        )
    }

    func reorderRuneForgeSources(
        sourceIDs: [PolicySourceID]
    ) async throws -> [DevelopmentPolicySource] {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Development Policy ordering is unavailable from this manager client."
        )
    }
}

struct RuneForgeSourceItem: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: PolicySourceID?
    let displayName: String
    let selectedPath: String
    let standardizedPath: String
    let origin: PolicySourceOrigin
    let rootKind: PolicySourceRootKind
    let active: Bool
    let interpretationState: PolicySourceInterpretationState
    let addedAt: Date
    let latestRevisionID: PolicySourceRevisionID?
    let lastIndexCursor: String?
    let latestObservation: String?
    let isOptimistic: Bool

    init(source: DevelopmentPolicySource) {
        id = source.id.description
        sourceID = source.id
        displayName = source.displayName
        selectedPath = source.selectedPath
        standardizedPath = source.standardizedPath
        origin = source.origin
        rootKind = source.rootKind
        active = source.active
        interpretationState = source.interpretationState
        addedAt = source.addedAt
        latestRevisionID = source.latestRevisionID
        lastIndexCursor = source.lastIndexCursor
        latestObservation = source.latestObservation
        isOptimistic = false
    }

    init(acceptedURL: URL, id: UUID = UUID()) {
        self.id = "pending-\(id.uuidString.lowercased())"
        sourceID = nil
        displayName = acceptedURL.lastPathComponent.isEmpty
            ? acceptedURL.path
            : acceptedURL.lastPathComponent
        selectedPath = acceptedURL.path
        standardizedPath = acceptedURL.standardizedFileURL.path
        origin = .userSelected
        rootKind = acceptedURL.hasDirectoryPath ? .directory : .unknown
        active = true
        interpretationState = .accepted
        addedAt = Date()
        latestRevisionID = nil
        lastIndexCursor = nil
        latestObservation = "Accepted immediately; manager catalog confirmation is pending."
        isOptimistic = true
    }

    func with(state: PolicySourceInterpretationState, observation: String) -> Self {
        Self(
            id: id,
            sourceID: sourceID,
            displayName: displayName,
            selectedPath: selectedPath,
            standardizedPath: standardizedPath,
            origin: origin,
            rootKind: rootKind,
            active: active,
            interpretationState: state,
            addedAt: addedAt,
            latestRevisionID: latestRevisionID,
            lastIndexCursor: lastIndexCursor,
            latestObservation: observation,
            isOptimistic: isOptimistic
        )
    }

    private init(
        id: String,
        sourceID: PolicySourceID?,
        displayName: String,
        selectedPath: String,
        standardizedPath: String,
        origin: PolicySourceOrigin,
        rootKind: PolicySourceRootKind,
        active: Bool,
        interpretationState: PolicySourceInterpretationState,
        addedAt: Date,
        latestRevisionID: PolicySourceRevisionID?,
        lastIndexCursor: String?,
        latestObservation: String?,
        isOptimistic: Bool
    ) {
        self.id = id
        self.sourceID = sourceID
        self.displayName = displayName
        self.selectedPath = selectedPath
        self.standardizedPath = standardizedPath
        self.origin = origin
        self.rootKind = rootKind
        self.active = active
        self.interpretationState = interpretationState
        self.addedAt = addedAt
        self.latestRevisionID = latestRevisionID
        self.lastIndexCursor = lastIndexCursor
        self.latestObservation = latestObservation
        self.isOptimistic = isOptimistic
    }
}

@MainActor
final class RuneForgeViewModel: ObservableObject {
    static let pollingInterval: Duration = .seconds(5)
    static let maximumSources = 100
    static let maximumViolations = 100
    static let maximumEvents = 100

    @Published private(set) var sources: [RuneForgeSourceItem] = []
    @Published private(set) var violations: [StjornarvaldViolationPageItem] = []
    @Published private(set) var events: [PolicyViolationEvent] = []
    @Published private(set) var evaluationActivity: [PolicyEvaluationActivity] = []
    @Published private(set) var projectLogIDs: [String] = []
    @Published private(set) var governingPolicy: GoverningPolicyIdentity?
    @Published private(set) var health: StjornarvaldManagerHealth?
    @Published private(set) var limitations: [String] = []
    var evaluationCoverageDescription: String {
        limitations.first { $0.hasPrefix("Automatic detection") }
            ?? "Automatic policy evaluation coverage is unavailable."
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?

    private let client: any RuneForgeManagerClientProtocol
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandID: UUID?

    init(client: any RuneForgeManagerClientProtocol) {
        self.client = client
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
        commandTask?.cancel()
    }

    var isDegraded: Bool { errorMessage != nil || health?.degraded == true }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await refreshNow()
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.pollingInterval) }
                catch { return }
                await refreshNow()
            }
        }
    }

    func pauseObservation() {
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func stop() {
        pauseObservation()
        commandTask?.cancel()
        commandTask = nil
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshNow()
        }
    }

    func refreshNow() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let snapshotRequest = client.runeForgeSnapshot()
            async let violationRequest = client.runeForgeViolations(
                cursor: 0,
                limit: Self.maximumViolations,
                state: nil
            )
            let (snapshot, page) = try await (snapshotRequest, violationRequest)
            try Task.checkCancellation()
            let registeredProjectIDs = (try? await client.runeForgeProjectIDs()) ?? []
            let pending = sources.filter(\.isOptimistic)
            let remote = snapshot.sources.prefix(Self.maximumSources).map(RuneForgeSourceItem.init)
            let remotePaths = Set(remote.map(\.standardizedPath))
            sources = Array(
                (Array(remote) + pending.filter { !remotePaths.contains($0.standardizedPath) })
                    .prefix(Self.maximumSources)
            )
            violations = Array(page.violations.prefix(Self.maximumViolations))
            events = Array(
                snapshot.violationEvents
                    .sorted { $0.sequence > $1.sequence }
                    .prefix(Self.maximumEvents)
            )
            projectLogIDs = Self.projectLogIDs(
                registeredProjectIDs: registeredProjectIDs,
                events: events
            )
            governingPolicy = snapshot.governingPolicy
            evaluationActivity = Array((snapshot.evaluationActivity ?? []).prefix(Self.maximumEvents))
            health = snapshot.health
            limitations = snapshot.limitations
            errorMessage = snapshot.health.lastError
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPolicySource(_ url: URL) {
        addPolicySources([url])
    }

    func addPolicySources(_ urls: [URL]) {
        var seen = Set<String>()
        let selectedURLs = urls.filter(\.isFileURL).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
        guard !selectedURLs.isEmpty, selectedURLs.count <= Self.maximumSources else {
            errorMessage = "Choose between 1 and \(Self.maximumSources) local files or folders."
            return
        }
        let optimisticSources = selectedURLs.map { RuneForgeSourceItem(acceptedURL: $0) }
        for optimistic in optimisticSources {
            sources.removeAll {
                $0.standardizedPath == optimistic.standardizedPath && $0.isOptimistic
            }
            sources.append(optimistic)
        }
        sources = Array(sources.prefix(Self.maximumSources))
        noticeMessage = "Accepted \(optimisticSources.count) active policy source\(optimisticSources.count == 1 ? "" : "s")."
        runCommand { [weak self] in
            guard let self else { return }
            for optimistic in optimisticSources {
                do {
                    let source = try await client.addRuneForgeSource(
                        path: optimistic.standardizedPath,
                        requestID: UUID()
                    )
                    try Task.checkCancellation()
                    replaceSource(id: optimistic.id, with: RuneForgeSourceItem(source: source))
                } catch is CancellationError {
                    return
                } catch {
                    updateSource(
                        id: optimistic.id,
                        state: .refreshPending,
                        observation: "Manager confirmation is pending; the accepted source remains visible."
                    )
                    errorMessage = error.localizedDescription
                    return
                }
            }
            noticeMessage = "Cataloging \(optimisticSources.count) Development Policy source\(optimisticSources.count == 1 ? "" : "s"); development is continuing."
        }
    }

    func movePolicySource(_ sourceID: String, to destinationSourceID: String) {
        guard sourceID != destinationSourceID,
              let source = sources.first(where: { $0.id == sourceID }),
              let destination = sources.first(where: { $0.id == destinationSourceID }),
              source.origin == .userSelected,
              destination.origin == .userSelected,
              let sourceIndex = sources.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = sources.firstIndex(where: { $0.id == destinationSourceID })
        else { return }

        var reordered = sources
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: min(destinationIndex, reordered.endIndex))
        guard reordered != sources else { return }
        let prior = sources
        sources = reordered
        let orderedIDs = reordered.compactMap { item -> PolicySourceID? in
            guard item.origin == .userSelected else { return nil }
            return item.sourceID
        }
        guard orderedIDs.count == reordered.filter({ $0.origin == .userSelected }).count else {
            sources = prior
            errorMessage = "Wait for every selected policy source to finish registering before reordering."
            return
        }
        let reorderCommandID = UUID()
        runCommand(id: reorderCommandID) { [weak self] in
            guard let self else { return }
            do {
                let persisted = try await client.reorderRuneForgeSources(sourceIDs: orderedIDs)
                guard commandID == reorderCommandID else { return }
                let remote = persisted.map(RuneForgeSourceItem.init)
                let builtIn = sources.filter { $0.origin == .builtInRavenForge }
                sources = Array((builtIn + remote).prefix(Self.maximumSources))
                noticeMessage = "Development Policy priority updated."
            } catch is CancellationError {
                guard commandID == reorderCommandID else { return }
                sources = prior
            } catch {
                guard commandID == reorderCommandID else { return }
                sources = prior
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshSource(_ item: RuneForgeSourceItem) {
        guard let sourceID = item.sourceID else {
            errorMessage = "This accepted source is waiting for manager catalog confirmation."
            return
        }
        updateSource(
            id: item.id,
            state: .refreshPending,
            observation: "Refresh requested; the active source remains available."
        )
        runCommand { [weak self] in
            guard let self else { return }
            do {
                let source = try await client.refreshRuneForgeSource(
                    sourceID: sourceID,
                    requestID: UUID()
                )
                replaceSource(id: item.id, with: RuneForgeSourceItem(source: source))
                noticeMessage = "Policy source refresh scheduled."
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeSource(_ item: RuneForgeSourceItem) {
        guard let sourceID = item.sourceID else {
            sources.removeAll { $0.id == item.id }
            noticeMessage = "Removed the locally pending policy source."
            return
        }
        runCommand { [weak self] in
            guard let self else { return }
            do {
                let source = try await client.removeRuneForgeSource(
                    sourceID: sourceID,
                    requestID: UUID()
                )
                if source.active {
                    replaceSource(id: item.id, with: RuneForgeSourceItem(source: source))
                } else {
                    sources.removeAll { $0.id == item.id }
                }
                noticeMessage = "Policy source removed from active evaluation."
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func scan() {
        runCommand { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await client.scheduleRuneForgeScan(
                    requestID: UUID(),
                    reason: "Rune Forge operator refresh"
                )
                noticeMessage = receipt.state == .scheduled
                    ? "Policy scan scheduled; development is continuing."
                    : "Policy scan is deferred; development is continuing."
                await refreshNow()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestExport(
        format: StjornarvaldExportFormat,
        destination: URL,
        filters: StjornarvaldExportFilters = StjornarvaldExportFilters()
    ) {
        guard destination.isFileURL, !isExporting else { return }
        isExporting = true
        runCommand { [weak self] in
            guard let self else { return }
            defer { isExporting = false }
            do {
                let receipt = try await client.requestRuneForgeExport(
                    format: format,
                    destination: destination.path,
                    filters: filters,
                    requestID: UUID()
                )
                noticeMessage = "\(receipt.message) \(receipt.destination ?? destination.path)"
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestProjectExport(
        projectID: String,
        format: StjornarvaldExportFormat,
        destination: URL
    ) {
        requestExport(
            format: format,
            destination: destination,
            filters: StjornarvaldExportFilters(projectID: projectID)
        )
    }

    static func projectLogIDs(
        registeredProjectIDs: [String],
        events: [PolicyViolationEvent]
    ) -> [String] {
        var seen = Set<String>()
        return (registeredProjectIDs + events.compactMap(\.candidate.scope.projectID))
            .filter { !$0.isEmpty && $0.utf8.count <= 1_024 && seen.insert($0).inserted }
            .sorted()
            .prefix(100)
            .map { $0 }
    }

    func latestEvent(for violationID: PolicyViolationID) -> PolicyViolationEvent? {
        events.first { $0.violationID == violationID }
    }

    func eventHistory(for violationID: PolicyViolationID) -> [PolicyViolationEvent] {
        events.filter { $0.violationID == violationID }
    }

    static func sourceStateTitle(_ state: PolicySourceInterpretationState) -> String {
        switch state {
        case .accepted: "Accepted"
        case .cataloging: "Cataloging"
        case .indexed: "Indexed"
        case .partiallyIndexed: "Partially indexed"
        case .refreshPending: "Refresh pending"
        case .sourceUnavailable: "Source unavailable"
        case .removedByUser: "Removed"
        }
    }

    static func violationStateTitle(_ state: PolicyViolationProjectionState) -> String {
        switch state {
        case .open: "Policy violation"
        case .corrected: "Corrected"
        case .repeated: "Repeated"
        case .reopened: "Reopened"
        case .disputed: "Interpretation observation"
        case .unresolvedAtHandoff: "Delivery pending"
        }
    }

    static func eventStateTitle(_ type: PolicyViolationEventType) -> String {
        switch type {
        case .opened: "Policy violation"
        case .repeated: "Repeated"
        case .evidenceUpdated: "Evidence updated"
        case .corrected: "Corrected"
        case .reopened: "Reopened"
        case .disputed: "Interpretation observation"
        }
    }

    private func runCommand(id: UUID = UUID(), _ operation: @escaping @MainActor () async -> Void) {
        commandID = id
        commandTask?.cancel()
        commandTask = Task { await operation() }
    }

    private func replaceSource(id: String, with source: RuneForgeSourceItem) {
        let replacementIndex = sources.firstIndex { $0.id == id }
            ?? sources.firstIndex { $0.standardizedPath == source.standardizedPath }
        sources.removeAll { $0.id == id || $0.standardizedPath == source.standardizedPath }
        sources.insert(source, at: min(replacementIndex ?? 0, sources.endIndex))
        sources = Array(sources.prefix(Self.maximumSources))
    }

    private func updateSource(
        id: String,
        state: PolicySourceInterpretationState,
        observation: String
    ) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index] = sources[index].with(state: state, observation: observation)
    }
}
