// RuntimesViewModel.swift
// Main-actor runtime capability, shell-policy, and bounded job presentation state.

import Foundation
import ForgeConductorCore

@MainActor
final class RuntimesViewModel: ObservableObject {
    @Published private(set) var jobs: [OperatorRuntimeJob] = []
    @Published private(set) var runtimePolicy: OperatorRuntimePolicy?
    @Published private(set) var settings: ManagerSettings?
    @Published var selectedJobID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSavingShellPolicy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedJob: OperatorRuntimeJob? { jobs.first { $0.jobID == selectedJobID } }

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let snapshotRequest = client.snapshot(limit: 100)
                async let settingsRequest = client.settings()
                let (snapshot, currentSettings) = try await (snapshotRequest, settingsRequest)
                try Task.checkCancellation()
                let loadedJobs = snapshot.runtimeJobs
                jobs = loadedJobs
                runtimePolicy = snapshot.runtime
                settings = currentSettings
                let priorSelection = selectedJobID
                if priorSelection == nil || !loadedJobs.contains(where: { $0.jobID == priorSelection }) {
                    selectedJobID = loadedJobs.first?.jobID
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func setShellEnabled(_ enabled: Bool) {
        guard !isSavingShellPolicy else { return }
        isSavingShellPolicy = true
        errorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                settings = try await client.updateSettings(
                    ManagerSettingsPatch(shellEnabled: enabled)
                )
                notice = enabled ? "Project shell tools enabled." : "Project shell tools disabled by operator policy."
            } catch {
                errorMessage = error.localizedDescription
            }
            isSavingShellPolicy = false
        }
    }
}
