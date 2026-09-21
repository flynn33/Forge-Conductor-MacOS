// AutonomyOperatorView.swift
// Native managed-run source list, detail inspector, and duplicate-safe start sheet.

import SwiftUI
import ForgeConductorCore

struct AutonomyOperatorView: View {
    @StateObject private var viewModel: AutonomyViewModel
    @State private var showingStartSheet = false
    @State private var showingCancelConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingAdvancedOverrides = false
    @State private var showingToolSelection = false
    @State private var showingCompletionChecks = false
    @State private var showingAdvancedCompletionControls = false
    private let onOpenProjects: () -> Void
    private let onOpenProvider: () -> Void

    init(
        client: any OperatorManagerClientProtocol,
        onOpenProjects: @escaping () -> Void = {},
        onOpenProvider: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: AutonomyViewModel(client: client))
        self.onOpenProjects = onOpenProjects
        self.onOpenProvider = onOpenProvider
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedRunID) {
                ForEach(viewModel.runs) { run in
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.horizontal.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.mission).lineLimit(1)
                            Text(run.state.replacingOccurrences(of: "_", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(run.runID)
                    .accessibilityIdentifier("autonomy-run-row-\(run.runID)")
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Button("Start Task…", systemImage: "plus") {
                    showingStartSheet = true
                }
                .disabled(!viewModel.autonomyStarted || viewModel.projects.isEmpty)
                .padding(10)
                .accessibilityIdentifier("autonomy-start")
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OperatorHeader(
                        title: "Autonomy",
                        subtitle: "Manager-owned provider sessions, leases, work, and completion gates",
                        isLoading: viewModel.isLoading,
                        titleAccessibilityIdentifier: "detail-autonomy",
                        subtitleAccessibilityIdentifier: "autonomy-operator-view",
                        onRefresh: viewModel.load
                    )
                    HStack {
                        Text("Managed autonomy")
                        Spacer()
                        OperatorStateBadge(state: viewModel.autonomyStarted ? "running" : "unavailable")
                    }
                    .accessibilityIdentifier("autonomy-mode")

                    if let error = viewModel.errorMessage {
                        OperatorErrorBanner(message: error, retry: viewModel.load)
                    }
                    if let notice = viewModel.notice {
                        OperatorNoticeBanner(message: notice)
                    }

                    if viewModel.projects.isEmpty {
                        Text("Register a repository in Projects before starting a managed run. The manager itself starts with the app; its lifecycle controls are in Manager.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("autonomy-project-prerequisite")
                    } else if viewModel.provider?.health != "reachable"
                                && viewModel.provider?.health != "contract_valid" {
                        Text("Authorize the project folder in Manager, then save the LM Studio endpoint and loaded model in Provider and run Test Connection.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("autonomy-provider-prerequisite")
                    }

                    if let run = viewModel.selectedRun {
                        runDetail(run)
                    } else if viewModel.errorMessage == nil, !viewModel.isLoading {
                        ContentUnavailableView(
                            "No Managed Runs",
                            systemImage: "bolt.horizontal.circle",
                            description: Text("Start a run after selecting a registered project and validated provider configuration.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(20)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingStartSheet) { startSheet }
        .onChange(of: viewModel.lastStartedRunID) { _, runID in
            if runID != nil { showingStartSheet = false }
        }
        .alert(
            "Cancel managed run?",
            isPresented: $showingCancelConfirmation,
            presenting: viewModel.selectedRun
        ) { _ in
            Button("Keep Running", role: .cancel) {}
            Button("Request Cancellation", role: .destructive) {
                viewModel.control(.cancel)
            }
        } message: { run in
            Text("Run \(run.runID)\n\(run.mission)\nThe manager will persist cancellation, stop active provider work and runtime jobs, and fence late results.")
        }
        .alert(
            "Delete task?",
            isPresented: $showingDeleteConfirmation,
            presenting: viewModel.selectedRun
        ) { _ in
            Button("Keep Task", role: .cancel) {}
            Button("Delete Task", role: .destructive) {
                viewModel.deleteSelectedRun()
            }
        } message: { run in
            Text("\(run.mission)\n\nThis permanently removes the settled task and its manager-owned run, session, tool, event, and runtime-job history. Project files are not changed.")
        }
        .task { viewModel.load() }
        .guidedHelpState(viewModel.guidedHelpState, for: .autonomy)
    }

    private func runDetail(_ run: OperatorRun) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Task") {
                VStack(alignment: .leading, spacing: 9) {
                    Text(run.mission)
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("autonomy-task-title")
                    LabeledContent("State") {
                        OperatorStateBadge(state: run.state)
                            .accessibilityIdentifier("autonomy-state")
                    }
                    LabeledContent("Current work item", value: run.workItem ?? "Preparing the next work item")
                    LabeledContent("Last model turn", value: run.lastModelTurnAt ?? "No model activity yet")
                    LabeledContent("Last tool activity", value: run.lastToolActivityAt ?? "No tool activity yet")
                }
            }

            GroupBox("Automatic continuity") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Protection", value: modeLabel(run.continuityMode))
                    LabeledContent(
                        "Successor work",
                        value: run.continuationPending ? "Preparing automatically" : "No rollover pending"
                    )
                    Text("Forge checkpoints and rolls this task into a successor session when supported; no handoff identifiers are required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let plan = run.completionPlan, !plan.obligations.isEmpty {
                        ForEach(plan.obligations) { obligation in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(
                                    obligation.title,
                                    systemImage: completionPassed(obligation, run: run)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    completionPassed(obligation, run: run) ? .green : .secondary
                                )
                                Text(obligation.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if run.completionGates.isEmpty {
                        Text("No completion-gate projection was published.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(run.completionGates, id: \.self) { gate in
                            Label(
                                gate,
                                systemImage: run.passedGates.contains(gate) ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(run.passedGates.contains(gate) ? .green : .secondary)
                        }
                    }
                    Button {
                        showingAdvancedCompletionControls.toggle()
                    } label: {
                        Label(
                            "Advanced controls",
                            systemImage: showingAdvancedCompletionControls
                                ? "chevron.down" : "chevron.right"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("run-completion-advanced-toggle")
                    if showingAdvancedCompletionControls {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom completion policy")
                                .font(.headline)
                            Text("Use an explicitly prepared signed native policy for specialized organizational checks. Routine tasks use the automatic plan above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(
                                "Import Custom Completion Policy…",
                                action: viewModel.chooseNativePolicy
                            )
                            .disabled(viewModel.policyImportInFlight || run.completionGates.isEmpty)
                            .accessibilityIdentifier("run-import-native-policy")
                            if viewModel.policyImportInFlight {
                                ProgressView("Preparing custom policy import…")
                                    .controlSize(.small)
                            }
                            Text("Prepare the signed XCTest package in Forge's protected home first. The imported policy must match this run, project generation, and explicitly selected custom checks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Completion checks")
                    Spacer()
                    GuidedHelpButton(context: .autonomyCompletionChecks)
                }
            }

            if let error = run.lastErrorSummary ?? run.lastErrorCode {
                GroupBox("Failure and retry") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).textSelection(.enabled)
                        LabeledContent("Classification", value: run.lastErrorCode ?? "Unavailable")
                        LabeledContent("Next retry", value: run.retryAt ?? "No retry scheduled")
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Pause") { viewModel.control(.pause) }
                    .accessibilityIdentifier("run-pause")
                    .disabled(!viewModel.canControl(.pause, run: run))
                Button("Resume") { viewModel.control(.resume) }
                    .accessibilityIdentifier("run-resume")
                    .disabled(!viewModel.canControl(.resume, run: run))
                Button("Cancel", role: .destructive) { showingCancelConfirmation = true }
                    .accessibilityIdentifier("run-cancel")
                    .disabled(!viewModel.canControl(.cancel, run: run))
                Button("Retry") { viewModel.control(.retry) }
                    .accessibilityIdentifier("run-retry")
                    .disabled(!viewModel.canControl(.retry, run: run))
                Button("Delete Task…", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .accessibilityIdentifier("run-delete")
                .disabled(!viewModel.canDelete(run))
                if let action = viewModel.controlInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Persisting \(action.rawValue) command")
                }
                if viewModel.deletionInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Deleting settled task")
                }
                Spacer()
                Button("Refresh Run", action: viewModel.refreshSelectedRun)
                    .disabled(viewModel.controlInFlight != nil)
            }
            Text("Commands are persisted by the manager. The GUI never mutates run state locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("run-controls-authority")

            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Run ID") { OperatorIdentifier(run.runID) }
                    LabeledContent("Project ID") { OperatorIdentifier(run.projectID) }
                    LabeledContent("Project generation", value: "\(run.projectGeneration)")
                    LabeledContent("Assignment ID") { OperatorIdentifier(run.assignmentID) }
                    LabeledContent("Provider", value: run.providerID ?? "Unavailable")
                    LabeledContent("Provider health") {
                        OperatorStateBadge(state: viewModel.provider?.health ?? "unavailable")
                    }
                    LabeledContent("Adapter", value: run.adapterID ?? "Unavailable")
                    LabeledContent("Model", value: run.modelKey ?? "Unavailable")
                    LabeledContent("Provider instance", value: run.providerInstanceID ?? "Unavailable")
                    LabeledContent("Current session") { OperatorIdentifier(run.activeSessionID) }
                    LabeledContent("Predecessor session") { OperatorIdentifier(run.predecessorSessionID) }
                    LabeledContent("Continuity operation") { OperatorIdentifier(run.activeOperationID) }
                    LabeledContent("Lease owner") { OperatorIdentifier(run.leaseOwner) }
                }
                .padding(.top, 8)
            }
            .accessibilityIdentifier("autonomy-technical-details")
        }
    }

    private var startSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Start Task").font(.title2.bold())
                Spacer()
                GuidedHelpButton(context: .autonomyStartTask)
            }
            Text("Choose the project, then type, paste, drop, or select the instructions and start. Forge supplies the saved model, task capabilities, completion checks, and continuity defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Project", selection: $viewModel.selectedProjectID) {
                Text("Choose a project").tag(String?.none)
                ForEach(viewModel.projects) { project in
                    Text("\(project.displayName) · generation \(project.projectGeneration)")
                        .tag(String?.some(project.projectID))
                }
            }
            .accessibilityIdentifier("run-start-project")
            .onChange(of: viewModel.selectedProjectID) { _, _ in
                viewModel.refreshToolPermissionsForSelection()
                viewModel.refreshInstructionArtifactsForSelection()
            }
            GroupBox("Instructions") {
                VStack(alignment: .leading, spacing: 9) {
                    if viewModel.availableInstructionPackages.isEmpty {
                        Text("No imported project packages are available. Add a file, folder, ZIP, or quick instructions below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("run-start-no-project-packages")
                    } else {
                        Text("Selected project packages")
                            .font(.caption.weight(.semibold))
                        ForEach(viewModel.availableInstructionPackages) { package in
                            Toggle(
                                isOn: Binding(
                                    get: { viewModel.selectedInstructionPackageIDs.contains(package.id) },
                                    set: { viewModel.setInstructionPackage(package.id, selected: $0) }
                                )
                            ) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(package.displayName)
                                        Text("\(package.documentCount ?? 0) documents · \(package.state)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(package.importReady == false)
                            .accessibilityIdentifier("run-start-package-\(package.id)")
                        }
                        Text("\(viewModel.selectedInstructionPackageIDs.count) selected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("run-start-package-selection-count")
                    }

                    Divider()
                    TextField("Optional quick instructions", text: $viewModel.mission, axis: .vertical)
                    .lineLimit(2...5)
                    .disabled(viewModel.instructionSourcePath != nil)
                    .accessibilityIdentifier("run-start-mission")
                    HStack {
                        Button("Add Instructions…") {
                            viewModel.chooseInstructionSource()
                        }
                        .accessibilityIdentifier("run-start-choose-instructions")
                        if let sourceName = viewModel.instructionSourceName {
                            Label(sourceName, systemImage: "doc.badge.checkmark")
                                .lineLimit(1)
                            Button("Remove") {
                                viewModel.clearInstructionSource()
                            }
                            .accessibilityIdentifier("run-start-remove-instructions")
                        } else {
                            Text("or drop a file, folder, or ZIP here")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("run-start-instruction-drop-target")
                        }
                    }
                    .font(.caption)
                    Text("Forge publishes quick text and added sources as immutable artifacts. Selected packages retain their stored content identity and displayed order.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard let source = urls.first else { return false }
                return viewModel.setInstructionSource(source)
            }

            GroupBox("Forge preparation") {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent(
                        "Status",
                        value: (viewModel.projectRunPreparation?.readiness.rawValue
                            ?? viewModel.runPreparation?.state
                            ?? "checking").replacingOccurrences(of: "_", with: " ")
                    )
                    Text(viewModel.projectRunPreparation?.detail
                        ?? viewModel.runPreparation?.detail
                        ?? "Forge is loading manager-owned defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let recovery = viewModel.preparationRecoveryAction {
                        Button(recoveryTitle(recovery)) {
                            performRecovery(recovery)
                        }
                        .accessibilityIdentifier("run-preparation-recovery")
                    }
                }
            }

            GroupBox("Task setup") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Model", value: viewModel.modelKey.isEmpty ? "Automatic" : viewModel.modelKey)
                    LabeledContent("Tools") {
                        HStack(spacing: 8) {
                            Text(toolSelectionSummary)
                            Button("Customize…") { showingToolSelection = true }
                                .accessibilityIdentifier("run-tools-customize")
                        }
                    }
                    LabeledContent("Completion checks") {
                        HStack(spacing: 8) {
                            Text(viewModel.completionSelectionSummary)
                            Button("Select…") { showingCompletionChecks = true }
                                .accessibilityIdentifier("run-completion-view")
                        }
                    }
                    Picker("On failure", selection: $viewModel.failureBehavior) {
                        Text("Pause for review").tag(AutonomousFailureBehavior.pauseForReview)
                        Text("Retry automatically").tag(AutonomousFailureBehavior.retryAutomatically)
                        Text("Stop task").tag(AutonomousFailureBehavior.stopTask)
                    }
                    .accessibilityIdentifier("run-failure-behavior")
                    if viewModel.failureBehavior == .retryAutomatically {
                        Stepper(
                            "Retry limit: \(viewModel.maximumRetries)",
                            value: $viewModel.maximumRetries,
                            in: 0...AutonomousFailurePolicy.maximumRetryLimit
                        )
                        .accessibilityIdentifier("run-retry-limit")
                    }
                    TextField(
                        "Custom failure instructions (optional)",
                        text: $viewModel.failureInstructions,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .accessibilityIdentifier("run-failure-instructions")
                    LabeledContent("Continuity", value: "Automatic")
                }
            }

            Button {
                showingAdvancedOverrides.toggle()
            } label: {
                Label(
                    "Customize",
                    systemImage: showingAdvancedOverrides ? "chevron.down" : "chevron.right"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("run-start-customize")

            if showingAdvancedOverrides {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Task label (optional)", text: $viewModel.assignmentID)
                        .accessibilityIdentifier("run-start-task-label")
                    Picker("Model", selection: $viewModel.modelOverrideKey) {
                        Text("Automatic — use the saved compatible model").tag("")
                        if let savedModel = viewModel.runPreparation?.modelKey,
                           !savedModel.isEmpty {
                            Text(savedModel).tag(savedModel)
                        }
                    }
                    .accessibilityIdentifier("run-start-model-picker")
                    Toggle("Allow network tools for this run", isOn: $viewModel.networkAllowed)
                        .accessibilityIdentifier("run-start-network")
                }
                .padding(.top, 8)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("run-start-error")
            }
            if viewModel.startRequiresReconciliation, !viewModel.isStarting {
                Button("Reconcile with Manager", action: viewModel.reconcileStart)
                    .accessibilityIdentifier("run-start-reconcile")
                Text("Forge resubmits the exact client-generated run identity. The manager returns the one durable run or creates it once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { showingStartSheet = false }
                    .accessibilityIdentifier("run-start-cancel")
                Spacer()
                if viewModel.isStarting { ProgressView().controlSize(.small) }
                Button("Start Task") {
                    viewModel.startRun()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
                .accessibilityIdentifier("run-start-confirm")
            }
        }
        .padding(22)
        .frame(width: 620)
        .guidedHelpContext(.autonomyStartTask)
        .sheet(isPresented: $showingToolSelection) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Customize Task Capabilities").font(.title2.bold())
                    Spacer()
                    GuidedHelpButton(context: .autonomyToolSelection)
                }
                Text("These project defaults are the sole source of tool permission truth for new tasks. Unavailable or forbidden tools cannot be granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ToolPermissionEditor(viewModel: viewModel)
                HStack {
                    Spacer()
                    Button("Done") { showingToolSelection = false }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("run-tools-done")
                }
            }
            .padding(22)
            .frame(width: 680, height: 620)
            .guidedHelpContext(.autonomyToolSelection)
        }
        .sheet(isPresented: $showingCompletionChecks) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Completion Checks").font(.title2.bold())
                    Spacer()
                    GuidedHelpButton(context: .autonomyCompletionChecks)
                }
                Text("Choose the deterministic checks Forge must satisfy before this task can complete. Forge may also derive relevant checks from the project and instructions.")
                    .foregroundStyle(.secondary)
                ForEach(CompletionCheckPreset.allCases) { check in
                    Toggle(
                        isOn: Binding(
                            get: { viewModel.selectedCompletionChecks.contains(check) },
                            set: { viewModel.setCompletionCheck(check, selected: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("run-completion-check-\(check.rawValue)")
                }
                Divider()
                if let plan = viewModel.preparedCompletionPlan, !plan.obligations.isEmpty {
                    Text("Prepared validation plan").font(.caption.weight(.semibold))
                    ForEach(plan.obligations) { obligation in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(obligation.title, systemImage: "checkmark.seal")
                            Text(obligation.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("run-completion-automatic")
                } else if viewModel.completionGates.isEmpty {
                    Text("Checks will be derived during task preparation.")
                        .accessibilityIdentifier("run-completion-automatic")
                } else {
                    ForEach(viewModel.completionGates.split(separator: "\n"), id: \.self) { gate in
                        Label(String(gate), systemImage: "checkmark.seal")
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Done") { showingCompletionChecks = false }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("run-completion-done")
                }
            }
            .padding(22)
            .frame(width: 620, height: 640)
            .guidedHelpContext(.autonomyCompletionChecks)
        }
    }

    private var toolSelectionSummary: String {
        guard let permissions = viewModel.toolPermissions else { return "Preparing…" }
        switch permissions.selectionMode {
        case .recommended:
            return "Recommended · \(permissions.effectiveCount) tools"
        case .allEligible:
            return "All eligible · \(permissions.effectiveCount) tools"
        case .explicit:
            return "Custom · \(permissions.effectiveCount) tools"
        }
    }

    private func modeLabel(_ raw: String) -> String {
        switch raw {
        case "managedAutonomous", "managed_autonomous":
            "Managed: automatic successor creation and continuation"
        case "externalMCPCompatibility", "external_mcp_compatibility":
            "External: handoff persisted; host session control unavailable"
        default:
            "Unavailable"
        }
    }

    private func completionPassed(
        _ obligation: CompletionObligation,
        run: OperatorRun
    ) -> Bool {
        if let customGateID = obligation.customGateID {
            return run.passedGates.contains(customGateID)
        }
        return run.passedGates.contains(ProjectInstructionQueueStore.builtInCompletionGate)
    }

    private func recoveryTitle(_ action: ManagerRunRecoveryAction) -> String {
        switch action {
        case .none: "No action required"
        case .selectProject: "Refresh Projects"
        case .authorizeProject: "Open Projects"
        case .configureProvider: "Open Model connection"
        case .reviewPermissions: "Review permissions"
        case .retryPreparation: "Refresh preparation"
        }
    }

    private func performRecovery(_ action: ManagerRunRecoveryAction) {
        switch action {
        case .none:
            break
        case .selectProject, .retryPreparation:
            viewModel.refreshPreparationRecovery()
        case .authorizeProject:
            onOpenProjects()
        case .configureProvider:
            onOpenProvider()
        case .reviewPermissions:
            showingToolSelection = true
            viewModel.refreshPreparationRecovery()
        }
    }
}
