// AutonomyViewModel.swift
// Main-actor managed-run observation and duplicate-safe run start command state.

import Foundation
import AppKit
import ForgeConductorCore
import UniformTypeIdentifiers

@MainActor
final class AutonomyViewModel: ObservableObject {
    @Published private(set) var runs: [OperatorRun] = []
    @Published private(set) var projects: [OperatorProject] = []
    @Published private(set) var provider: OperatorProvider?
    @Published private(set) var runPreparation: OperatorRunPreparation?
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
    @Published private(set) var policyImportInFlight = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?

    private let client: any OperatorManagerClientProtocol
    private let policyInstaller = NativeValidationPolicyInstaller()
    private var loadTask: Task<Void, Never>?
    private var pendingStartRequest: OperatorRunStartRequest?
    private var didApplyPreparationDefaults = false
    private var networkOverrideForNextPreparation: Bool?

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
                runPreparation = snapshot.runPreparation
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
                if let preparation = snapshot.runPreparation {
                    if !didApplyPreparationDefaults {
                        if providerID.isEmpty { providerID = preparation.providerID ?? "" }
                        if adapterID.isEmpty { adapterID = preparation.adapterID }
                        if modelKey.isEmpty { modelKey = preparation.modelKey ?? "" }
                        if allowedTools.isEmpty {
                            allowedTools = preparation.allowedTools.joined(separator: "\n")
                        }
                        if completionGates.isEmpty {
                            completionGates = preparation.completionGates.joined(separator: "\n")
                        }
                        if let networkOverrideForNextPreparation {
                            networkAllowed = networkOverrideForNextPreparation
                            self.networkOverrideForNextPreparation = nil
                        } else {
                            networkAllowed = preparation.networkAllowed
                        }
                        didApplyPreparationDefaults = true
                    }
                } else {
                    if providerID.isEmpty { providerID = snapshot.provider?.providerID ?? "" }
                    if modelKey.isEmpty { modelKey = snapshot.provider?.modelKey ?? "" }
                }
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
        guard let request = makeStartRequest() else { return }
        isStarting = true
        startRequiresReconciliation = true
        errorMessage = nil
        notice = nil
        pendingStartRequest = request
        submitStart(request)
    }

    func makeStartRequest() -> OperatorRunStartRequest? {
        guard canStart, let project = selectedProject else { return nil }
        let providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapterID = adapterID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelKey = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedTools = parsedList(allowedTools)
        let completionGates = parsedList(completionGates)
        let preparation = runPreparation
        return OperatorRunStartRequest(
            runID: UUID().uuidString.lowercased(),
            projectID: project.projectID,
            projectGeneration: project.projectGeneration,
            assignmentID: assignmentID.nilIfBlank,
            mission: mission.trimmingCharacters(in: .whitespacesAndNewlines),
            providerID: providerID == preparation?.providerID ? nil : providerID,
            adapterID: adapterID == preparation?.adapterID ? nil : adapterID,
            modelKey: modelKey == preparation?.modelKey ? nil : modelKey,
            allowedTools: Set(allowedTools) == Set(preparation?.allowedTools ?? [])
                ? nil : allowedTools,
            completionGates: completionGates == preparation?.completionGates
                ? nil : completionGates,
            networkAllowed: networkAllowed == preparation?.networkAllowed
                ? nil : networkAllowed,
            expectedProviderConfigurationRevision:
                preparation?.providerConfigurationRevision,
            expectedToolCatalogRevision: preparation?.toolCatalogRevision,
            maximumInlineOutputBytes: 64 * 1_024
        )
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
            var startWasSubmitted = false
            do {
                var admittedRequest = request
                if request.expectedPreparedRunRevision == nil {
                    do {
                        let prepared = try await client.prepareRun(request)
                        guard prepared.readiness == .ready
                                || prepared.readiness == .automaticallyPreparing else {
                            throw OperatorManagerClientError.configurationRejected(
                                code: "run_preparation_not_ready",
                                message: prepared.detail
                            )
                        }
                        admittedRequest = request.expectingPreparedDescriptor(prepared)
                        pendingStartRequest = admittedRequest
                    } catch OperatorManagerClientError.capabilityUnavailable {
                        // A legacy in-process client may not expose preparation yet.
                        // The manager Start route still performs its existing validation.
                    }
                }
                startWasSubmitted = true
                let run = try await client.startRun(admittedRequest)
                guard run.runID == admittedRequest.runID else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager returned run \(run.runID) for request \(admittedRequest.runID)"
                    )
                }
                acceptStartedRun(run)
            } catch let clientError as OperatorManagerClientError {
                if !startWasSubmitted {
                    pendingStartRequest = nil
                    startRequiresReconciliation = false
                    errorMessage = clientError.localizedDescription
                    notice = "Run preparation did not complete. No run was submitted."
                } else if case .configurationRejected(let code, _) = clientError {
                    pendingStartRequest = nil
                    startRequiresReconciliation = false
                    errorMessage = clientError.localizedDescription
                    if code == "run_preparation_stale" {
                        clearAutomaticallyAppliedPreparationValues()
                        didApplyPreparationDefaults = false
                        notice = "Forge is refreshing changed run preparation. No run was persisted."
                        load()
                    } else {
                        notice = "Correct the run configuration and submit it again. No run was persisted."
                    }
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
        startRequiresReconciliation = false
    }

    private func clearAutomaticallyAppliedPreparationValues() {
        guard let preparation = runPreparation else { return }
        if providerID == preparation.providerID { providerID = "" }
        if adapterID == preparation.adapterID { adapterID = "" }
        if modelKey == preparation.modelKey { modelKey = "" }
        if Set(parsedList(allowedTools)) == Set(preparation.allowedTools) {
            allowedTools = ""
        }
        if parsedList(completionGates) == preparation.completionGates {
            completionGates = ""
        }
        if networkAllowed == preparation.networkAllowed {
            networkAllowed = false
        } else {
            networkOverrideForNextPreparation = networkAllowed
        }
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

    func chooseNativePolicy() {
        guard !policyImportInFlight, let run = selectedRun,
              projects.contains(where: { $0.projectID == run.projectID }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Policy"
        policyImportInFlight = true
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard response == .OK, let file = panel.url else {
                    self.policyImportInFlight = false
                    return
                }
                self.importNativePolicy(file, selectedRunID: run.runID)
            }
        }
    }

    private func importNativePolicy(_ file: URL, selectedRunID: String) {
        guard self.selectedRunID == selectedRunID else {
            policyImportInFlight = false
            return
        }
        errorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            defer { policyImportInFlight = false }
            do {
                let run = try await client.runStatus(runID: selectedRunID)
                let project = try await client.projectStatus(projectID: run.projectID)
                guard self.selectedRunID == run.runID,
                      run.projectID == project.projectID,
                      run.projectGeneration == project.projectGeneration,
                      let runUUID = UUID(uuidString: run.runID),
                      let projectUUID = UUID(uuidString: run.projectID) else {
                    throw AutonomyError.invalidRequest("managed run or project generation changed before policy import")
                }
                let binding = NativeValidationPolicyInstaller.RunBinding(
                    runID: RunID(runUUID), projectID: ProjectID(projectUUID),
                    projectGeneration: ProjectGeneration(run.projectGeneration),
                    completionGates: run.completionGates,
                    projectRoot: URL(fileURLWithPath: project.canonicalRoot, isDirectory: true)
                )
                let receipt = try await policyInstaller.importPolicy(from: file, for: binding)
                guard self.selectedRunID == run.runID else { return }
                notice = "Native validation policy imported for run \(receipt.runID). The manager will verify signed test results before completion."
                refreshSelectedRun()
            } catch {
                errorMessage = "Native policy import failed: \(error.localizedDescription)"
            }
        }
    }

    func canControl(_ action: OperatorRunControlAction, run: OperatorRun) -> Bool {
        guard controlInFlight == nil else { return false }
        switch action {
        case .pause:
            return ![
                "paused", "awaiting_bootstrap", "cancel_requested", "completed", "cancelled", "failed_terminal",
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
