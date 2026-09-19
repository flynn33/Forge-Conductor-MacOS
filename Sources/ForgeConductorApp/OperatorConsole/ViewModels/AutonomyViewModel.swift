// AutonomyViewModel.swift
// Main-actor managed-run observation and duplicate-safe run start command state.

import Foundation
import AppKit
import ForgeConductorCore
import UniformTypeIdentifiers

enum ToolCheckboxState: Equatable {
    case unchecked
    case mixed
    case checked
}

@MainActor
final class AutonomyViewModel: ObservableObject {
    @Published private(set) var runs: [OperatorRun] = []
    @Published private(set) var projects: [OperatorProject] = []
    @Published private(set) var provider: OperatorProvider?
    @Published private(set) var runPreparation: OperatorRunPreparation?
    @Published private(set) var projectRunPreparation: ManagerRunPreparationResult?
    @Published private(set) var toolPermissions: ManagerToolPermissionSnapshot?
    @Published private(set) var instructionQueue: OperatorInstructionQueue?
    @Published private(set) var selectedInstructionPackageIDs: [String] = []
    @Published var toolSearch = ""
    @Published private(set) var autonomyStarted = false
    @Published var selectedRunID: String?
    @Published var selectedProjectID: String?
    @Published var mission = ""
    @Published private(set) var instructionSourcePath: String?
    @Published var assignmentID = ""
    @Published var providerID = ""
    @Published var adapterID = "forge.native-session-host"
    @Published var modelKey = ""
    @Published var modelOverrideKey = ""
    @Published var allowedTools = ""
    @Published var completionGates = ""
    @Published var networkAllowed = false
    @Published private(set) var isLoading = false
    @Published private(set) var isStarting = false
    @Published private(set) var startRequiresReconciliation = false
    @Published private(set) var lastStartedRunID: String?
    @Published private(set) var controlInFlight: OperatorRunControlAction?
    @Published private(set) var policyImportInFlight = false
    @Published private(set) var toolPermissionUpdateInFlight = false
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
    var preparedCompletionPlan: AutomaticCompletionPlan? {
        projectRunPreparation?.descriptor?.validationPlan.automaticPlan
    }

    var taskDraft: AutonomyTaskDraft {
        AutonomyTaskDraft(
            projectID: selectedProjectID,
            packageIDs: selectedInstructionPackageIDs,
            quickInstructions: mission,
            localImportPath: instructionSourcePath,
            optionalAssignmentLabel: assignmentID.nilIfBlank,
            networkAllowed: networkAllowed,
            modelOverride: modelOverrideKey.nilIfBlank
        )
    }

    var canStart: Bool {
        !isStarting
            && !startRequiresReconciliation
            && selectedProject != nil
            && taskDraft.hasInstructionInput
    }

    var availableInstructionPackages: [OperatorInstructionPackage] {
        (instructionQueue?.packages ?? []).sorted {
            $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position
        }
    }

    var selectedInstructionPackages: [OperatorInstructionPackage] {
        let selected = Set(selectedInstructionPackageIDs)
        return availableInstructionPackages.filter { selected.contains($0.id) }
    }

    var instructionSourceName: String? {
        instructionSourcePath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    func chooseInstructionSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Use Instructions"
        panel.message = "Choose a file, folder, or ZIP. Forge will preserve and inspect it before Start."
        if panel.runModal() == .OK, let url = panel.url {
            setInstructionSource(url)
        }
    }

    @discardableResult
    func setInstructionSource(_ url: URL) -> Bool {
        guard url.isFileURL else {
            errorMessage = "Instruction sources must be local files or folders."
            return false
        }
        instructionSourcePath = url.standardizedFileURL.path
        errorMessage = nil
        notice = "\(url.lastPathComponent) will use the same immutable artifact pipeline as pasted instructions."
        return true
    }

    func clearInstructionSource() {
        instructionSourcePath = nil
    }

    func refreshInstructionArtifactsForSelection() {
        selectedInstructionPackageIDs = []
        instructionQueue = nil
        guard let project = selectedProject else { return }
        Task { [weak self] in
            await self?.refreshInstructionQueue(for: project, reportErrors: true)
        }
    }

    func toggleInstructionPackage(_ packageID: String) {
        setInstructionPackage(
            packageID,
            selected: !selectedInstructionPackageIDs.contains(packageID)
        )
    }

    func setInstructionPackage(_ packageID: String, selected shouldSelect: Bool) {
        guard let package = availableInstructionPackages.first(where: { $0.id == packageID }),
              package.importReady != false else { return }
        var selected = Set(selectedInstructionPackageIDs)
        if shouldSelect {
            selected.insert(packageID)
        } else {
            selected.remove(packageID)
        }
        selectedInstructionPackageIDs = availableInstructionPackages.compactMap {
            selected.contains($0.id) ? $0.id : nil
        }
    }

    private func refreshInstructionQueue(
        for project: OperatorProject,
        reportErrors: Bool
    ) async {
        do {
            let queue = try await client.instructionQueue(
                projectID: project.projectID,
                generation: project.projectGeneration
            )
            guard selectedProjectID == project.projectID else { return }
            instructionQueue = queue
            let available = Set(queue.packages.map(\.id))
            selectedInstructionPackageIDs.removeAll { !available.contains($0) }
        } catch OperatorManagerClientError.capabilityUnavailable(_) {
            if selectedProjectID == project.projectID { instructionQueue = nil }
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    var preparationRecoveryAction: ManagerRunRecoveryAction? {
        guard let action = projectRunPreparation?.recoveryAction, action != .none else {
            return nil
        }
        return action
    }

    var filteredToolEntries: [ManagerToolCatalogEntry] {
        guard let toolPermissions else { return [] }
        let query = toolSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return toolPermissions.tools }
        return toolPermissions.tools.filter {
            $0.id.lowercased().contains(query)
                || $0.displayName.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
                || $0.categoryDisplayName.lowercased().contains(query)
        }
    }

    var visibleToolCategories: [ManagerToolCategory] {
        let categories = Set(filteredToolEntries.map(\.category))
        return ManagerToolCategory.allCases.filter(categories.contains)
    }

    var allToolSelectionState: ToolCheckboxState {
        selectionState(for: toolPermissions?.tools.filter(\.available) ?? [])
    }

    func categorySelectionState(_ category: ManagerToolCategory) -> ToolCheckboxState {
        selectionState(for: toolPermissions?.tools.filter {
            $0.category == category && $0.available
        } ?? [])
    }

    func isToolSelected(_ toolID: String) -> Bool {
        toolPermissions?.selectedToolIDs.contains(toolID) == true
            || toolPermissions?.effectiveToolIDs.contains(toolID) == true
    }

    func refreshToolPermissionsForSelection() {
        guard let project = selectedProject else {
            toolPermissions = nil
            return
        }
        toolPermissions = nil
        Task { [weak self] in
            await self?.refreshToolPermissions(for: project, reportErrors: true)
        }
    }

    func setTool(_ toolID: String, selected: Bool) {
        guard let snapshot = toolPermissions,
              let tool = snapshot.tools.first(where: { $0.id == toolID }),
              tool.available || (!selected && snapshot.selectedToolIDs.contains(toolID)) else {
            return
        }
        var selectedIDs = Set(snapshot.selectedToolIDs)
        if selected { selectedIDs.insert(toolID) } else { selectedIDs.remove(toolID) }
        saveToolPermissions(mode: .explicit, selectedToolIDs: selectedIDs)
    }

    func setCategory(_ category: ManagerToolCategory, selected: Bool) {
        guard let snapshot = toolPermissions else { return }
        let categoryIDs = Set(snapshot.tools.filter {
            $0.category == category && $0.available
        }.map(\.id))
        var selectedIDs = Set(snapshot.selectedToolIDs)
        if selected {
            selectedIDs.formUnion(categoryIDs)
        } else {
            selectedIDs.subtract(categoryIDs)
        }
        saveToolPermissions(mode: .explicit, selectedToolIDs: selectedIDs)
    }

    func setAllTools(selected: Bool) {
        saveToolPermissions(
            mode: selected ? .allEligible : .explicit,
            selectedToolIDs: []
        )
    }

    func restoreRecommendedTools() {
        saveToolPermissions(mode: .recommended, selectedToolIDs: [])
    }

    private func selectionState(for entries: [ManagerToolCatalogEntry]) -> ToolCheckboxState {
        guard !entries.isEmpty else { return .unchecked }
        let selected = Set(toolPermissions?.effectiveToolIDs ?? [])
        let count = entries.lazy.filter { selected.contains($0.id) }.count
        if count == 0 { return .unchecked }
        return count == entries.count ? .checked : .mixed
    }

    private func refreshToolPermissions(
        for project: OperatorProject,
        reportErrors: Bool
    ) async {
        do {
            let snapshot = try await client.projectToolPermissions(
                projectID: project.projectID,
                generation: project.projectGeneration
            )
            guard selectedProjectID == project.projectID else { return }
            applyToolPermissions(snapshot)
        } catch OperatorManagerClientError.capabilityUnavailable(_) {
            if selectedProjectID == project.projectID { toolPermissions = nil }
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    private func saveToolPermissions(
        mode: ManagerToolSelectionMode,
        selectedToolIDs: Set<String>
    ) {
        guard !toolPermissionUpdateInFlight,
              let snapshot = toolPermissions,
              selectedProjectID == snapshot.projectID else { return }
        toolPermissionUpdateInFlight = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { toolPermissionUpdateInFlight = false }
            do {
                let updated = try await client.updateProjectToolPermissions(
                    ManagerToolPermissionUpdate(
                        projectID: snapshot.projectID,
                        projectGeneration: snapshot.projectGeneration,
                        expectedPreferenceRevision: snapshot.preferenceRevision,
                        selectionMode: mode,
                        selectedToolIDs: selectedToolIDs.sorted()
                    )
                )
                guard selectedProjectID == updated.projectID else { return }
                applyToolPermissions(updated)
                notice = "Saved project capability defaults. New runs will freeze this exact resolved grant."
            } catch {
                errorMessage = error.localizedDescription
                if let project = selectedProject {
                    await refreshToolPermissions(for: project, reportErrors: false)
                }
            }
        }
    }

    private func applyToolPermissions(_ snapshot: ManagerToolPermissionSnapshot) {
        toolPermissions = snapshot
        allowedTools = snapshot.effectiveToolIDs.joined(separator: "\n")
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
                if let project = selectedProject {
                    await refreshToolPermissions(for: project, reportErrors: false)
                    await refreshInstructionQueue(for: project, reportErrors: false)
                } else {
                    toolPermissions = nil
                    instructionQueue = nil
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
        projectRunPreparation = nil
        pendingStartRequest = request
        submitStart(request)
    }

    func makeStartRequest() -> OperatorRunStartRequest? {
        guard canStart, let project = selectedProject else { return nil }
        let providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapterID = adapterID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelKey = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelOverrideKey = modelOverrideKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedTools = parsedList(allowedTools)
        let completionGates = parsedList(completionGates)
        let preparation = runPreparation
        let projectPermissions = toolPermissions.flatMap {
            $0.projectID == project.projectID
                && $0.projectGeneration == project.projectGeneration ? $0 : nil
        }
        return OperatorRunStartRequest(
            runID: UUID().uuidString.lowercased(),
            projectID: project.projectID,
            projectGeneration: project.projectGeneration,
            assignmentID: assignmentID.nilIfBlank,
            mission: instructionSourceName.map {
                "Follow the imported instructions in \($0)."
            } ?? mission.nilIfBlank
                ?? "Follow the selected instruction artifacts in their displayed order.",
            localInstructionSourcePath: instructionSourcePath,
            localInstructionPackageIDs: selectedInstructionPackageIDs,
            localQuickInstructions: mission.nilIfBlank,
            providerID: providerID.isEmpty || providerID == preparation?.providerID
                ? nil : providerID,
            adapterID: adapterID.isEmpty || adapterID == preparation?.adapterID
                ? nil : adapterID,
            modelKey: modelOverrideKey.isEmpty
                ? (modelKey.isEmpty || modelKey == preparation?.modelKey ? nil : modelKey)
                : modelOverrideKey,
            allowedTools: allowedTools.isEmpty
                || Set(allowedTools) == Set(projectPermissions?.effectiveToolIDs
                    ?? preparation?.allowedTools ?? [])
                ? nil : allowedTools,
            completionGates: completionGates.isEmpty
                || completionGates == preparation?.completionGates
                ? nil : completionGates,
            networkAllowed: networkAllowed == preparation?.networkAllowed
                ? nil : networkAllowed,
            expectedProviderConfigurationRevision:
                preparation?.providerConfigurationRevision,
            expectedToolCatalogRevision: projectPermissions?.catalogRevision
                ?? preparation?.toolCatalogRevision,
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
                var admittedRequest = try await admitInstructionArtifact(request)
                if admittedRequest.expectedPreparedRunRevision == nil {
                    do {
                        var preparationResult = try await client.prepareRun(admittedRequest)
                        if preparationResult.readiness == .automaticallyPreparing,
                           preparationResult.projectID == request.projectID,
                           preparationResult.projectGeneration != request.projectGeneration {
                            admittedRequest = try await admitInstructionArtifact(
                                admittedRequest.replacingProjectGenerationForInstructionReassembly(
                                    preparationResult.projectGeneration
                                )
                            )
                            preparationResult = try await client.prepareRun(admittedRequest)
                        }
                        projectRunPreparation = preparationResult
                        guard preparationResult.readiness == .ready,
                              let prepared = preparationResult.descriptor else {
                            pendingStartRequest = nil
                            startRequiresReconciliation = false
                            errorMessage = preparationResult.readiness == .failed
                                ? preparationResult.detail : nil
                            notice = preparationResult.detail
                            isStarting = false
                            return
                        }
                        guard prepared.projectID == admittedRequest.projectID,
                              prepared.projectGeneration == admittedRequest.projectGeneration else {
                            throw OperatorManagerClientError.invalidPayload(
                                "manager returned preparation for a different project generation"
                            )
                        }
                        admittedRequest = admittedRequest.expectingPreparedDescriptor(prepared)
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

    private func admitInstructionArtifact(
        _ request: OperatorRunStartRequest
    ) async throws -> OperatorRunStartRequest {
        guard request.instructionArtifactSHA256 == nil else { return request }
        let staged: URL?
        let sourcePath: String?
        if let selectedPath = request.localInstructionSourcePath {
            staged = nil
            sourcePath = selectedPath
        } else if let quickInstructions = request.localQuickInstructions {
            let url = try await Self.stagePastedInstructions(
                quickInstructions,
                runID: request.runID
            )
            staged = url
            sourcePath = url.path
        } else {
            staged = nil
            sourcePath = nil
        }
        defer {
            if let staged {
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(
                        at: staged.deletingLastPathComponent()
                    )
                }
            }
        }
        let artifact = try await client.assembleRunInstructionArtifact(
            projectID: request.projectID,
            generation: request.projectGeneration,
            runID: request.runID,
            packageIDs: request.localInstructionPackageIDs,
            sourcePath: sourcePath
        )
        guard artifact.unresolvedDocumentCount == 0 else {
            throw OperatorManagerClientError.invalidPayload(
                "The instructions contain \(artifact.unresolvedDocumentCount) unresolved document(s)."
            )
        }
        let admitted = request.usingInstructionArtifact(artifact)
        pendingStartRequest = admitted
        return admitted
    }

    private nonisolated static func stagePastedInstructions(
        _ instructions: String,
        runID: String
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "forge-run-\(runID.lowercased())-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                let url = directory.appendingPathComponent("instructions.txt")
                try Data(instructions.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                return url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private func acceptStartedRun(_ run: OperatorRun) {
        runs.removeAll { $0.runID == run.runID }
        runs.insert(run, at: 0)
        selectedRunID = run.runID
        notice = "Run \(run.runID) accepted by the manager."
        lastStartedRunID = run.runID
        pendingStartRequest = nil
        projectRunPreparation = nil
        mission = ""
        instructionSourcePath = nil
        selectedInstructionPackageIDs = []
        assignmentID = ""
        modelOverrideKey = ""
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

    func refreshPreparationRecovery() {
        guard !isStarting, let action = preparationRecoveryAction else { return }
        switch action {
        case .selectProject:
            load()
        case .retryPreparation:
            startRun()
        case .reviewPermissions:
            notice = "Review the task capability checkboxes, then try Start again."
        case .authorizeProject, .configureProvider:
            break
        case .none:
            break
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
