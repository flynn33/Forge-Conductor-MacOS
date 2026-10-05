import Foundation
import ForgeConductorCore

/// Read-only preparation for the setup sheet. Reviewing a registered project
/// does not make it Dashboard's active project or bind a model session to it.
@MainActor
final class GuidedSetupReviewViewModel: ObservableObject {
    @Published var selectedProjectID: String? {
        didSet {
            guard oldValue != selectedProjectID else { return }
            selectionRequestRevision &+= 1
            loadedProject = nil
            instructionQueue = nil
            selectionErrorMessage = nil
            isLoadingSelection = false
        }
    }
    @Published private(set) var projects: [OperatorProject] = []
    @Published private(set) var loadedProject: OperatorProject?
    @Published private(set) var instructionQueue: OperatorInstructionQueue?
    @Published private(set) var isLoadingProjects = false
    @Published private(set) var isLoadingSelection = false
    @Published private(set) var projectsErrorMessage: String?
    @Published private(set) var selectionErrorMessage: String?

    private let client: any OperatorManagerClientProtocol
    private var projectsRequestRevision: UInt64 = 0
    private var selectionRequestRevision: UInt64 = 0
    private var operatorSnapshot: OperatorSnapshot?
    private var providerIntegrations: ProviderIntegrationsSnapshot?
    private var providerConfigurationRevision: String?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedProject: OperatorProject? {
        loadedProject ?? projects.first { $0.projectID == selectedProjectID }
    }

    var errorMessage: String? { projectsErrorMessage ?? selectionErrorMessage }
    var isLoading: Bool { isLoadingProjects || isLoadingSelection }

    func loadProjects(preferredProjectID: String? = nil) async {
        projectsRequestRevision &+= 1
        selectionRequestRevision &+= 1
        let revision = projectsRequestRevision
        loadedProject = nil
        instructionQueue = nil
        selectionErrorMessage = nil
        isLoadingSelection = false
        isLoadingProjects = true
        projectsErrorMessage = nil
        defer {
            if projectsRequestRevision == revision { isLoadingProjects = false }
        }
        do {
            let evidence = try await loadProviderEvidence()
            try Task.checkCancellation()
            guard projectsRequestRevision == revision else { return }
            projects = evidence.snapshot.projects.filter { $0.lifecycleState == "active" }
            publishProviderEvidence(evidence)
            let preferred = selectedProjectID ?? preferredProjectID
            if let preferred,
               let project = projects.first(where: {
                   $0.projectID.caseInsensitiveCompare(preferred) == .orderedSame
               }) {
                selectedProjectID = project.projectID
            } else {
                selectedProjectID = projects.count == 1 ? projects.first?.projectID : nil
            }
        } catch {
            guard !Task.isCancelled, projectsRequestRevision == revision else { return }
            projects = []
            selectedProjectID = nil
            operatorSnapshot = nil
            providerIntegrations = nil
            providerConfigurationRevision = nil
            projectsErrorMessage = error.localizedDescription
        }
    }

    func loadSelection() async {
        selectionRequestRevision &+= 1
        let revision = selectionRequestRevision
        loadedProject = nil
        instructionQueue = nil
        selectionErrorMessage = nil
        guard let projectID = selectedProjectID else { return }
        isLoadingSelection = true
        defer {
            if selectionRequestRevision == revision { isLoadingSelection = false }
        }
        do {
            async let providerEvidence = loadProviderEvidence()
            let project = try await client.projectStatus(projectID: projectID)
            try validate(project, requestedProjectID: projectID)
            try Task.checkCancellation()
            guard selectionRequestRevision == revision,
                  selectedProjectID == projectID else { return }
            let queue = try await client.instructionQueue(
                projectID: project.projectID,
                generation: project.projectGeneration
            )
            try validate(queue, project: project)
            let evidence = try await providerEvidence
            try Task.checkCancellation()
            guard selectionRequestRevision == revision,
                  selectedProjectID == projectID else { return }
            loadedProject = project
            instructionQueue = queue
            publishProviderEvidence(evidence)
        } catch {
            guard !Task.isCancelled, selectionRequestRevision == revision,
                  selectedProjectID == projectID else { return }
            selectionErrorMessage = error.localizedDescription
        }
    }

    func snapshot(base: RigOperationalSnapshot) -> RigOperationalSnapshot {
        let preparation = RigOperationalSnapshot.compose(
            operatorSnapshot: operatorSnapshot,
            autonomy: nil,
            runeForge: nil,
            providerIntegrations: providerIntegrations,
            instructionQueue: instructionQueue,
            progressProject: selectedProject,
            allowUnboundRunFallback: false
        )
        var result = base
        result.selectedProvider = preparation.selectedProvider
        result.providerHealth = preparation.providerHealth
        result.providerModel = preparation.providerModel
        result.projectName = preparation.projectName
        result.projectCompletedSteps = preparation.projectCompletedSteps
        result.projectTotalSteps = preparation.projectTotalSteps
        result.projectCompletedPackages = preparation.projectCompletedPackages
        result.projectTotalPackages = preparation.projectTotalPackages
        result.projectProgressState = preparation.projectProgressState
        result.guidedSetupPreparationFingerprint = if !isLoading,
            errorMessage == nil,
            loadedProject != nil {
            RigOperationalSnapshot.guidedSetupPreparationFingerprint(
                selectedProvider: preparation.selectedProvider,
                providerConfigurationRevision: providerConfigurationRevision,
                providerSelectionRevision: providerIntegrations?.selectionRevision,
                project: loadedProject,
                packages: instructionQueue?.packages ?? []
            )
        } else {
            nil
        }
        return result
    }

    private struct ProviderEvidence {
        let snapshot: OperatorSnapshot
        let integrations: ProviderIntegrationsSnapshot
        let configurationRevision: String?
    }

    private func loadProviderEvidence() async throws -> ProviderEvidence {
        async let snapshot = client.snapshot(limit: 100, cursor: nil)
        async let integrations = client.providerIntegrations()
        let (observedSnapshot, observedIntegrations) = try await (snapshot, integrations)
        try Task.checkCancellation()
        let revision = if observedIntegrations.selectedProviderID == .lmStudio {
            try await client.providerConfiguration().revision
        } else {
            observedSnapshot.runPreparation?.providerConfigurationRevision
        }
        return ProviderEvidence(
            snapshot: observedSnapshot,
            integrations: observedIntegrations,
            configurationRevision: revision
        )
    }

    private func publishProviderEvidence(_ evidence: ProviderEvidence) {
        operatorSnapshot = evidence.snapshot
        providerIntegrations = evidence.integrations
        providerConfigurationRevision = evidence.configurationRevision
    }

    private func validate(_ project: OperatorProject, requestedProjectID: String) throws {
        guard project.projectID.caseInsensitiveCompare(requestedProjectID) == .orderedSame,
              project.projectGeneration > 0,
              project.lifecycleState == "active" else {
            throw OperatorManagerClientError.invalidPayload(
                "The selected project is no longer active at its registered identity. Refresh Projects."
            )
        }
    }

    private func validate(_ queue: OperatorInstructionQueue, project: OperatorProject) throws {
        guard queue.projectID.caseInsensitiveCompare(project.projectID) == .orderedSame,
              queue.projectGeneration == project.projectGeneration,
              queue.packages.allSatisfy({
                  $0.projectID.caseInsensitiveCompare(project.projectID) == .orderedSame
                      && $0.projectGeneration == project.projectGeneration
              }) else {
            throw OperatorManagerClientError.invalidPayload(
                "Instruction packages no longer match the selected project generation. Refresh the review."
            )
        }
    }
}
