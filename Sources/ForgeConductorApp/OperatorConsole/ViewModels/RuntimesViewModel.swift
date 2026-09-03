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
    @Published private(set) var cancellingJobID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedJob: OperatorRuntimeJob? { jobs.first { $0.jobID == selectedJobID } }

    var canCancelSelectedJob: Bool {
        guard let selectedJob else { return false }
        return canCancel(selectedJob)
    }

    func canCancel(_ job: OperatorRuntimeJob) -> Bool {
        guard cancellingJobID == nil,
              let state = RuntimeJobState(rawValue: job.state) else {
            return false
        }
        return state.isOperatorCancellable
    }

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
                applyJobs(loadedJobs)
                runtimePolicy = snapshot.runtime
                settings = currentSettings
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

    func cancelSelectedJob() {
        guard let job = selectedJob, canCancel(job) else { return }
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        cancellingJobID = job.jobID
        errorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            var acceptedJob: OperatorRuntimeJob?
            var commandError: Error?
            do {
                let updated = try await client.cancelRuntimeJob(jobID: job.jobID)
                guard updated.jobID == job.jobID else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager returned job \(updated.jobID) for cancellation of \(job.jobID)"
                    )
                }
                acceptedJob = updated
                replaceJob(updated)
                notice = "Cancellation persisted for runtime job \(job.jobID)."
            } catch {
                commandError = error
            }

            do {
                let snapshot = try await client.snapshot(limit: 100)
                applyJobs(snapshot.runtimeJobs)
                if let current = jobs.first(where: { $0.jobID == job.jobID }),
                   !Self.isCancellableState(current.state),
                   commandError != nil {
                    commandError = nil
                    notice = "Runtime job \(job.jobID) reconciled in state \(current.state)."
                }
            } catch {
                if acceptedJob != nil {
                    errorMessage = "Cancellation was accepted, but the authoritative job refresh failed: \(error.localizedDescription)"
                } else if let commandError {
                    errorMessage = "Cancellation outcome could not be reconciled: \(commandError.localizedDescription); refresh failed: \(error.localizedDescription)"
                } else {
                    errorMessage = error.localizedDescription
                }
                commandError = nil
            }

            if let commandError {
                errorMessage = "Cancellation outcome for job \(job.jobID) requires retry or refresh: \(commandError.localizedDescription)"
                notice = nil
            }
            cancellingJobID = nil
        }
    }

    private func applyJobs(_ loadedJobs: [OperatorRuntimeJob]) {
        jobs = loadedJobs
        let priorSelection = selectedJobID
        if priorSelection == nil || !loadedJobs.contains(where: { $0.jobID == priorSelection }) {
            selectedJobID = loadedJobs.first?.jobID
        }
    }

    private func replaceJob(_ job: OperatorRuntimeJob) {
        if let index = jobs.firstIndex(where: { $0.jobID == job.jobID }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        selectedJobID = job.jobID
    }

    private static func isCancellableState(_ rawValue: String) -> Bool {
        guard let state = RuntimeJobState(rawValue: rawValue) else { return false }
        return state.isOperatorCancellable
    }
}
