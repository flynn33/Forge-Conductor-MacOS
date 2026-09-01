// AutonomyViewModel.swift
// Main-actor managed-run observation and duplicate-safe run start command state.

import Foundation

@MainActor
final class AutonomyViewModel: ObservableObject {
    @Published private(set) var runs: [OperatorRun] = []
    @Published private(set) var projects: [OperatorProject] = []
    @Published private(set) var provider: OperatorProvider?
    @Published private(set) var autonomyStarted = false
    @Published var selectedRunID: String?
    @Published var selectedProjectID: String?
    @Published var mission = ""
    @Published var assignmentID = ""
    @Published var providerID = ""
    @Published var adapterID = "forge.native-session-host"
    @Published var modelKey = ""
    @Published var allowedTools = ""
    @Published var completionGates = ""
    @Published var networkAllowed = false
    @Published private(set) var isLoading = false
    @Published private(set) var isStarting = false
    @Published private(set) var startRequiresReconciliation = false
    @Published private(set) var lastStartedRunID: String?
    @Published private(set) var controlInFlight: OperatorRunControlAction?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?
    private var pendingStartRequest: OperatorRunStartRequest?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedRun: OperatorRun? { runs.first { $0.runID == selectedRunID } }
    var selectedProject: OperatorProject? { projects.first { $0.projectID == selectedProjectID } }

    var canStart: Bool {
        !isStarting
            && !startRequiresReconciliation
            && selectedProject != nil
            && !mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !adapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parsedList(allowedTools).isEmpty
            && !parsedList(completionGates).isEmpty
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let snapshotRequest = client.snapshot(limit: 100)
                async let statusRequest = client.autonomyStatus()
                let (snapshot, status) = try await (snapshotRequest, statusRequest)
                try Task.checkCancellation()
                let loadedProjects = snapshot.projects
                let loadedRuns = snapshot.runs
                projects = loadedProjects
                runs = loadedRuns
                provider = snapshot.provider
                autonomyStarted = status.started
                let priorProjectSelection = selectedProjectID
                if priorProjectSelection == nil
                    || !loadedProjects.contains(where: { $0.projectID == priorProjectSelection }) {
                    selectedProjectID = loadedProjects.first?.projectID
                }
                let priorRunSelection = selectedRunID
                if priorRunSelection == nil || !loadedRuns.contains(where: { $0.runID == priorRunSelection }) {
                    selectedRunID = loadedRuns.first?.runID
                }
                if providerID.isEmpty { providerID = snapshot.provider?.providerID ?? "" }
                if modelKey.isEmpty { modelKey = snapshot.provider?.modelKey ?? "" }
                if let pending = pendingStartRequest,
                   let accepted = loadedRuns.first(where: { $0.runID == pending.runID }) {
                    acceptStartedRun(accepted)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func startRun() {
        guard canStart, let project = selectedProject else { return }
        isStarting = true
        startRequiresReconciliation = true
        errorMessage = nil
        notice = nil
        let request = OperatorRunStartRequest(
            runID: UUID().uuidString.lowercased(),
            projectID: project.projectID,
            projectGeneration: project.projectGeneration,
            assignmentID: assignmentID.nilIfBlank,
            mission: mission.trimmingCharacters(in: .whitespacesAndNewlines),
            providerID: providerID.trimmingCharacters(in: .whitespacesAndNewlines),
            adapterID: adapterID.trimmingCharacters(in: .whitespacesAndNewlines),
            modelKey: modelKey.trimmingCharacters(in: .whitespacesAndNewlines),
            allowedTools: parsedList(allowedTools),
            completionGates: parsedList(completionGates),
            networkAllowed: networkAllowed,
            maximumInlineOutputBytes: 64 * 1_024
        )
        pendingStartRequest = request
        submitStart(request)
    }

    func reconcileStart() {
        guard !isStarting, let request = pendingStartRequest else { return }
        isStarting = true
        errorMessage = nil
        notice = "Reconciling the exact run request \(request.runID) with the manager."
        submitStart(request)
    }

    private func submitStart(_ request: OperatorRunStartRequest) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let run = try await client.startRun(request)
                guard run.runID == request.runID else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager returned run \(run.runID) for request \(request.runID)"
                    )
                }
                acceptStartedRun(run)
            } catch let clientError as OperatorManagerClientError {
                if case .configurationRejected = clientError {
                    pendingStartRequest = nil
                    startRequiresReconciliation = false
                    errorMessage = clientError.localizedDescription
                    notice = "Correct the run configuration and submit it again. No run was persisted."
                } else {
                    errorMessage = "Run \(request.runID) must be reconciled before another start: \(clientError.localizedDescription)"
                    notice = nil
                }
            } catch {
                errorMessage = "Run \(request.runID) must be reconciled before another start: \(error.localizedDescription)"
                notice = nil
            }
            isStarting = false
        }
    }

    private func acceptStartedRun(_ run: OperatorRun) {
        runs.removeAll { $0.runID == run.runID }
        runs.insert(run, at: 0)
        selectedRunID = run.runID
        notice = "Run \(run.runID) accepted by the manager."
        lastStartedRunID = run.runID
        pendingStartRequest = nil
        mission = ""
        assignmentID = ""
        allowedTools = ""
        completionGates = ""
        startRequiresReconciliation = false
    }

    func refreshSelectedRun() {
        guard !isLoading, let runID = selectedRunID else { return }
        isLoading = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let run = try await client.runStatus(runID: runID)
                runs.removeAll { $0.runID == run.runID }
                runs.insert(run, at: 0)
                selectedRunID = run.runID
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func canControl(_ action: OperatorRunControlAction, run: OperatorRun) -> Bool {
        guard controlInFlight == nil else { return false }
        switch action {
        case .pause:
            return ![
                "paused", "cancel_requested", "completed", "cancelled", "failed_terminal",
            ].contains(run.state)
        case .resume:
            return run.state == "paused"
        case .cancel:
            return !["completed", "cancel_requested", "cancelled", "failed_terminal"].contains(run.state)
        case .retry:
            return [
                "failed_recoverable", "blocked_configuration", "waiting_provider", "waiting_resource",
                "retry_wait",
            ].contains(run.state)
        case .checkpoint, .rollover:
            return false
        }
    }

    func control(_ action: OperatorRunControlAction) {
        guard let run = selectedRun, canControl(action, run: run) else { return }
        controlInFlight = action
        errorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            var shouldReload = false
            do {
                let updated = try await client.controlRun(runID: run.runID, action: action)
                runs.removeAll { $0.runID == updated.runID }
                runs.insert(updated, at: 0)
                selectedRunID = updated.runID
                notice = "Run \(action.rawValue) command persisted by the manager."
                shouldReload = true
            } catch {
                errorMessage = error.localizedDescription
            }
            controlInFlight = nil
            if shouldReload {
                load()
            }
        }
    }

    private func parsedList(_ source: String) -> [String] {
        source
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
