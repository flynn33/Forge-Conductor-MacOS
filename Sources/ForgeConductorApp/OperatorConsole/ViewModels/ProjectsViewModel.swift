// ProjectsViewModel.swift
// Main-actor projection and typed project commands for the native operator UI.

import Foundation

@MainActor
final class ProjectsViewModel: ObservableObject {
    private static let maximumPendingReconciliations = 100

    private struct PendingRegistration: Sendable, Equatable {
        let request: OperatorProjectRegistrationRequest
        let projectID: String?
        let code: String
        let message: String
        let durable: Bool

        var key: String {
            projectID?.lowercased() ?? "path:\(request.path)"
        }
    }

    private struct PendingRelink: Sendable, Equatable {
        let projectID: String
        let displayName: String
        let generation: UInt64
        let path: String
        let operationID: String?
        let durable: Bool
    }

    @Published private(set) var projects: [OperatorProject] = []
    @Published var selectedProjectID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastUpdated: Date?
    @Published private var pendingRegistrations: [String: PendingRegistration] = [:]
    @Published private var pendingRelinks: [String: PendingRelink] = [:]

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedProject: OperatorProject? {
        projects.first { $0.projectID == selectedProjectID }
    }

    var pendingRelinkPath: String? {
        guard let selectedProjectID else { return nil }
        return pendingRelinks[selectedProjectID.lowercased()]?.path
    }

    var pendingRegistrationPath: String? {
        nextPendingRegistration?.request.path
    }

    var pendingRegistrationMessage: String? {
        nextPendingRegistration?.message
    }

    var pendingRegistrationProjectID: String? {
        nextPendingRegistration?.projectID
    }

    var canDiscardPendingRegistration: Bool {
        nextPendingRegistration?.durable == false
    }

    var canDiscardPendingRelink: Bool {
        guard let selectedProjectID else { return false }
        return pendingRelinks[selectedProjectID.lowercased()]?.durable == false
    }

    private var nextPendingRegistration: PendingRegistration? {
        pendingRegistrations.values.sorted { $0.key < $1.key }.first
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.snapshot(limit: 100)
                try Task.checkCancellation()
                let loadedProjects = snapshot.projects
                projects = loadedProjects
                rebuildPendingTransitions(
                    from: loadedProjects,
                    pendingProjectRegistrations: snapshot.pendingProjectRegistrations
                )
                let priorSelection = selectedProjectID
                if priorSelection == nil || !loadedProjects.contains(where: { $0.projectID == priorSelection }) {
                    selectedProjectID = loadedProjects.first?.projectID
                }
                lastUpdated = Date()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func register(path: String, displayName: String?) {
        guard !isLoading else { return }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            errorMessage = "Choose a canonical project folder before registering."
            return
        }
        isLoading = true
        errorMessage = nil
        notice = nil
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        performRegistration(
            OperatorProjectRegistrationRequest(
                path: trimmedPath,
                displayName: trimmedName?.isEmpty == false ? trimmedName : nil,
                repositoryIdentity: nil
            )
        )
    }

    func reconcilePendingRegistration() {
        guard !isLoading, let pending = nextPendingRegistration else { return }
        performRegistration(pending.request)
    }

    func discardPendingRegistration() {
        guard let pending = nextPendingRegistration, !pending.durable else { return }
        pendingRegistrations.removeValue(forKey: pending.key)
    }

    func resetSelectedProject() {
        guard !isLoading, let project = selectedProject else { return }
        isLoading = true
        errorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await client.resetProject(
                    projectID: project.projectID,
                    generation: project.projectGeneration
                )
                notice = "Reset generation \(receipt.priorGeneration) → \(receipt.newGeneration); fenced \(receipt.invalidatedBindingCount) binding(s)."
                let refreshed = try await client.projectStatus(projectID: project.projectID)
                projects.removeAll { $0.projectID == refreshed.projectID }
                projects.append(refreshed)
                projects.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                selectedProjectID = refreshed.projectID
                lastUpdated = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func relinkSelectedProject(to path: String) {
        guard !isLoading, let project = selectedProject else { return }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (path as NSString).isAbsolutePath else {
            errorMessage = "Choose an existing project folder before relinking."
            return
        }
        let nextGeneration = project.projectGeneration.addingReportingOverflow(1)
        guard !nextGeneration.overflow else {
            errorMessage = "The selected project generation cannot be advanced."
            return
        }
        performRelink(
            PendingRelink(
                projectID: project.projectID,
                displayName: project.displayName,
                generation: project.projectGeneration,
                path: path,
                operationID: nil,
                durable: false
            )
        )
    }

    func reconcilePendingRelink() {
        guard !isLoading,
              let selectedProjectID,
              let pendingRelink = pendingRelinks[selectedProjectID.lowercased()] else { return }
        performRelink(pendingRelink)
    }

    func discardPendingRelink() {
        guard let selectedProjectID,
              pendingRelinks[selectedProjectID.lowercased()]?.durable == false else { return }
        pendingRelinks.removeValue(forKey: selectedProjectID.lowercased())
    }

    private func performRelink(_ request: PendingRelink) {
        let nextGeneration = request.generation.addingReportingOverflow(1)
        guard !nextGeneration.overflow else {
            errorMessage = "The selected project generation cannot be advanced."
            return
        }
        let key = request.projectID.lowercased()
        guard pendingRelinks[key] != nil
                || pendingRelinks.count < Self.maximumPendingReconciliations else {
            errorMessage = "Reconcile or dismiss a pending relink before starting another."
            return
        }
        pendingRelinks[key] = request
        isLoading = true
        errorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await client.relinkProject(
                    projectID: request.projectID,
                    generation: request.generation,
                    path: request.path
                )
                guard receipt.projectID.caseInsensitiveCompare(request.projectID) == .orderedSame,
                      receipt.priorGeneration == request.generation,
                      receipt.newGeneration == nextGeneration.partialValue else {
                    throw OperatorManagerClientError.invalidPayload(
                        "project relink receipt did not match the selected project generation"
                    )
                }
                let refreshed = try await client.projectStatus(projectID: request.projectID)
                guard refreshed.projectGeneration == receipt.newGeneration,
                      refreshed.canonicalRoot == receipt.canonicalRoot else {
                    throw OperatorManagerClientError.invalidPayload(
                        "project relink status did not match the committed receipt"
                    )
                }
                projects.removeAll {
                    $0.projectID.caseInsensitiveCompare(refreshed.projectID) == .orderedSame
                }
                projects.append(refreshed)
                projects.sort {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                selectedProjectID = refreshed.projectID
                notice = receipt.reconciled
                    ? "Reconciled the committed relink at generation \(receipt.newGeneration)."
                    : "Relinked \(request.displayName) at generation \(receipt.newGeneration)."
                pendingRelinks.removeValue(forKey: request.projectID.lowercased())
                lastUpdated = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func performRegistration(_ request: OperatorProjectRegistrationRequest) {
        let replaysPendingRequest = pendingRegistrations.values.contains {
            $0.request == request
        }
        guard replaysPendingRequest
                || pendingRegistrations.count < Self.maximumPendingReconciliations else {
            errorMessage = "Reconcile or dismiss a pending registration before starting another."
            return
        }
        isLoading = true
        errorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await client.registerProject(request)
                switch outcome {
                case .committed(let project, let reconciled):
                    projects.removeAll { $0.projectID == project.projectID }
                    projects.append(project)
                    projects.sort {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                            == .orderedAscending
                    }
                    selectedProjectID = project.projectID
                    pendingRegistrations = pendingRegistrations.filter { _, pending in
                        pending.projectID?.caseInsensitiveCompare(project.projectID) != .orderedSame
                            && pending.request != request
                    }
                    notice = reconciled
                        ? "Reconciled \(project.displayName) at generation \(project.projectGeneration)."
                        : "Registered \(project.displayName) at generation \(project.projectGeneration)."
                    lastUpdated = Date()
                case .reconciliationRequired(let pending):
                    let retained = PendingRegistration(
                        request: pending.request,
                        projectID: pending.projectID,
                        code: pending.code,
                        message: pending.message,
                        durable: pending.projectID != nil
                    )
                    pendingRegistrations = pendingRegistrations.filter { _, existing in
                        existing.request != pending.request
                    }
                    pendingRegistrations[retained.key] = retained
                    if let projectID = pending.projectID {
                        selectedProjectID = projectID
                    }
                    errorMessage = OperatorManagerClientError.reconciliationRequired(
                        code: pending.code,
                        message: pending.message
                    ).localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func rebuildPendingTransitions(
        from projects: [OperatorProject],
        pendingProjectRegistrations: [OperatorProjectRegistrationTransition]
    ) {
        var durableRegistrations: [String: PendingRegistration] = [:]
        var durableRelinks: [String: PendingRelink] = [:]
        for registration in pendingProjectRegistrations.prefix(
            Self.maximumPendingReconciliations
        ) where registration.state == "reconciliation_required" {
            let pending = PendingRegistration(
                request: OperatorProjectRegistrationRequest(
                    path: registration.requestPath,
                    displayName: registration.requestedDisplayName,
                    repositoryIdentity: registration.repositoryIdentityAssertion
                ),
                projectID: registration.projectID,
                code: "project_registration_reconciliation_required",
                message: "The manager retained this exact registration request before its transition completed.",
                durable: true
            )
            durableRegistrations[pending.key] = pending
        }
        for project in projects {
            guard let transition = project.pendingTransition,
                  transition.state == "reconciliation_required" else { continue }
            switch transition.kind {
            case "registration":
                let pending = PendingRegistration(
                    request: OperatorProjectRegistrationRequest(
                        path: transition.requestPath,
                        displayName: transition.requestedDisplayName,
                        repositoryIdentity: transition.repositoryIdentityAssertion
                    ),
                    projectID: project.projectID,
                    code: "project_registration_reconciliation_required",
                    message: "The manager retained this exact registration request after an interrupted transition.",
                    durable: true
                )
                durableRegistrations[pending.key] = pending
            case "relink":
                guard let expectedGeneration = transition.expectedGeneration else { continue }
                durableRelinks[project.projectID.lowercased()] = PendingRelink(
                    projectID: project.projectID,
                    displayName: project.displayName,
                    generation: expectedGeneration,
                    path: transition.requestPath,
                    operationID: transition.operationID,
                    durable: true
                )
            default:
                continue
            }
        }
        let unresolvedLocal = pendingRegistrations
            .filter { _, pending in !pending.durable && pending.projectID == nil }
            .sorted { $0.key < $1.key }
        var rebuiltRegistrations = durableRegistrations
        for (key, pending) in unresolvedLocal
            where rebuiltRegistrations.count < Self.maximumPendingReconciliations {
            guard !rebuiltRegistrations.values.contains(where: {
                $0.request == pending.request
            }) else { continue }
            rebuiltRegistrations[key] = pending
        }
        pendingRegistrations = rebuiltRegistrations

        let unresolvedRelinks = pendingRelinks
            .filter { _, pending in !pending.durable }
            .sorted { $0.key < $1.key }
        var rebuiltRelinks = durableRelinks
        for (key, pending) in unresolvedRelinks
            where rebuiltRelinks.count < Self.maximumPendingReconciliations {
            guard rebuiltRelinks[key] == nil else { continue }
            rebuiltRelinks[key] = pending
        }
        pendingRelinks = rebuiltRelinks
    }
}
