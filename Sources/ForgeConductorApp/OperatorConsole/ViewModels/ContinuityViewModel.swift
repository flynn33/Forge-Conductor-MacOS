// ContinuityViewModel.swift
// Project continuity identity projection with explicit project-scoped deletion.

import Foundation
import ForgeConductorCore

@MainActor
final class ContinuityViewModel: ObservableObject {
    @Published private(set) var projectIDs: [String] = []
    @Published var selectedProjectID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var deletingProjectID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var commandErrorMessage: String?
    @Published private(set) var notice: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var canDeleteSelectedProject: Bool {
        selectedProjectID != nil && !isLoading && deletingProjectID == nil
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
                let loadedProjectIDs = snapshot.projects
                    .filter { $0.continuity?.state != "unavailable" }
                    .map { $0.projectID.lowercased() }
                    .sorted()
                projectIDs = loadedProjectIDs
                if let selectedProjectID,
                   loadedProjectIDs.contains(selectedProjectID) {
                    self.selectedProjectID = selectedProjectID
                } else {
                    selectedProjectID = loadedProjectIDs.first
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func deleteSelectedProjectContinuity() {
        guard canDeleteSelectedProject,
              let selectedProjectID,
              let identifier = UUID(uuidString: selectedProjectID) else {
            commandErrorMessage = "The selected continuity project has an invalid identity."
            return
        }

        deletingProjectID = selectedProjectID
        commandErrorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = ContinuityHistoryClearRequest(
                    scope: .project,
                    projectID: ProjectID(identifier)
                )
                let receipt = try await client.clearContinuityHistory(request)
                guard receipt.scope == .project,
                      receipt.requestedProjectID == request.projectID else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager returned a continuity deletion receipt for a different project"
                    )
                }
                projectIDs.removeAll { $0 == selectedProjectID }
                self.selectedProjectID = projectIDs.first
                notice = receipt.clearedOperationCount == 0
                    ? "This project's continuity data was already clear."
                    : "Deleted continuity data for project \(selectedProjectID)."
            } catch {
                commandErrorMessage = error.localizedDescription
            }
            deletingProjectID = nil
            if commandErrorMessage == nil {
                load()
            }
        }
    }
}
