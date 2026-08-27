// ProjectsViewModel.swift
// Main-actor projection and typed project commands for the native operator UI.

import Foundation

@MainActor
final class ProjectsViewModel: ObservableObject {
    @Published private(set) var projects: [OperatorProject] = []
    @Published var selectedProjectID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastUpdated: Date?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedProject: OperatorProject? {
        projects.first { $0.projectID == selectedProjectID }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let project = try await client.registerProject(
                    OperatorProjectRegistrationRequest(
                        path: trimmedPath,
                        displayName: trimmedName?.isEmpty == false ? trimmedName : nil,
                        repositoryIdentity: nil
                    )
                )
                projects.removeAll { $0.projectID == project.projectID }
                projects.append(project)
                projects.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                selectedProjectID = project.projectID
                notice = "Registered \(project.displayName) at generation \(project.projectGeneration)."
                lastUpdated = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
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
}
