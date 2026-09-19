// AutonomyOperatorView.swift
// Native managed-run source list, detail inspector, and duplicate-safe start sheet.

import SwiftUI
import AppKit
import ForgeConductorCore

struct AutonomyOperatorView: View {
    @StateObject private var viewModel: AutonomyViewModel
    @State private var showingStartSheet = false
    @State private var showingCancelConfirmation = false
    @State private var showingAdvancedOverrides = false
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
        .task { viewModel.load() }
        .accessibilityIdentifier("autonomy-operator-view")
    }

    private func runDetail(_ run: OperatorRun) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Run") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("State") {
                        OperatorStateBadge(state: run.state)
                            .accessibilityIdentifier("autonomy-state")
                    }
                    LabeledContent("Mode", value: modeLabel(run.continuityMode))
                    LabeledContent("Run ID") { OperatorIdentifier(run.runID) }
                    LabeledContent("Project ID") { OperatorIdentifier(run.projectID) }
                    LabeledContent("Project generation", value: "\(run.projectGeneration)")
                    LabeledContent("Mission", value: run.mission)
                    LabeledContent("Lease owner") { OperatorIdentifier(run.leaseOwner) }
                    LabeledContent("Current work item", value: run.workItem ?? "Unavailable")
                    LabeledContent("Last model turn", value: run.lastModelTurnAt ?? "Unavailable")
                    LabeledContent("Last tool activity", value: run.lastToolActivityAt ?? "Unavailable")
                }
            }

            GroupBox("Provider session") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Provider", value: run.providerID ?? "Unavailable")
                    LabeledContent("Provider health") {
                        OperatorStateBadge(state: viewModel.provider?.health ?? "unavailable")
                    }
                    LabeledContent("Adapter", value: run.adapterID ?? "Unavailable")
                    LabeledContent("Model", value: run.modelKey ?? "Unavailable")
                    LabeledContent("Instance", value: run.providerInstanceID ?? "Unavailable")
                    LabeledContent("Current session") { OperatorIdentifier(run.activeSessionID) }
                    LabeledContent("Predecessor session") { OperatorIdentifier(run.predecessorSessionID) }
                    LabeledContent("Continuity operation") { OperatorIdentifier(run.activeOperationID) }
                }
            }

            GroupBox("Completion checks") {
                VStack(alignment: .leading, spacing: 10) {
                    if run.completionGates.isEmpty {
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
                    Button("Advanced: Import Custom Validation…", action: viewModel.chooseNativePolicy)
                        .disabled(viewModel.policyImportInFlight || run.completionGates.isEmpty)
                        .accessibilityIdentifier("run-import-native-policy")
                    if viewModel.policyImportInFlight {
                        ProgressView("Preparing native policy import…")
                            .controlSize(.small)
                    }
                    Text("Prepare the signed XCTest package in Forge's protected home first. The imported policy must match this run, project generation, and completion gates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                if let action = viewModel.controlInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Persisting \(action.rawValue) command")
                }
                Spacer()
                Button("Refresh Run", action: viewModel.refreshSelectedRun)
                    .disabled(viewModel.controlInFlight != nil)
            }
            Text("Commands are persisted by the manager. The GUI never mutates run state locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("run-controls-authority")
        }
    }

    private var startSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start Task").font(.title2.bold())
            Text("Choose the project, enter the instructions, and start. Forge supplies the saved model, task capabilities, completion checks, and continuity defaults.")
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
            }
            TextField("Instructions", text: $viewModel.mission, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("run-start-mission")

            GroupBox("Forge preparation") {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent(
                        "Status",
                        value: (viewModel.projectRunPreparation?.readiness.rawValue
                            ?? viewModel.runPreparation?.state
                            ?? "checking").replacingOccurrences(of: "_", with: " ")
                    )
                    LabeledContent("Model", value: viewModel.modelKey.isEmpty ? "Waiting for saved model" : viewModel.modelKey)
                    LabeledContent(
                        "Capabilities",
                        value: viewModel.toolPermissions.map {
                            "\($0.effectiveCount) of \($0.availableCount) granted"
                        } ?? "\(viewModel.allowedTools.split(whereSeparator: { $0 == "," || $0.isNewline }).count) selected"
                    )
                    LabeledContent("Completion", value: viewModel.completionGates.isEmpty ? "Waiting for checks" : "Automatic")
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

            toolPermissionEditor

            DisclosureGroup("Advanced overrides", isExpanded: $showingAdvancedOverrides) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Assignment ID (optional)", text: $viewModel.assignmentID)
                    HStack {
                        TextField("Provider", text: $viewModel.providerID)
                        TextField("Adapter", text: $viewModel.adapterID)
                    }
                    TextField("Model", text: $viewModel.modelKey)
                        .accessibilityIdentifier("run-start-model")
                    TextField(
                        "Capability IDs (advanced override; comma or newline separated)",
                        text: $viewModel.allowedTools,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .accessibilityIdentifier("run-start-tool-policy")
                    TextField("Completion gates (comma or newline separated)", text: $viewModel.completionGates, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("run-start-completion-gates")
                    Toggle("Allow network tools for this run", isOn: $viewModel.networkAllowed)
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
    }

    private var toolPermissionEditor: some View {
        GroupBox("Task capabilities") {
            if let permissions = viewModel.toolPermissions {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        NativeTriStateCheckbox(
                            title: "Allow all tools",
                            identifier: "run-tools-allow-all",
                            state: viewModel.allToolSelectionState,
                            enabled: !viewModel.toolPermissionUpdateInFlight
                        ) {
                            viewModel.setAllTools(
                                selected: viewModel.allToolSelectionState != .checked
                            )
                        }
                        .frame(minWidth: 180, alignment: .leading)
                        Spacer()
                        Button("Select none") { viewModel.setAllTools(selected: false) }
                            .disabled(viewModel.toolPermissionUpdateInFlight)
                            .accessibilityIdentifier("run-tools-select-none")
                        Button("Restore recommended") {
                            viewModel.restoreRecommendedTools()
                        }
                        .disabled(viewModel.toolPermissionUpdateInFlight)
                        .accessibilityIdentifier("run-tools-restore-recommended")
                    }
                    TextField("Search capabilities", text: $viewModel.toolSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("run-tools-search")
                    Text("\(permissions.effectiveCount) granted · \(permissions.availableCount) available · saved for this project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("run-tools-selection-count")

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.visibleToolCategories, id: \.self) { category in
                                VStack(alignment: .leading, spacing: 6) {
                                    NativeTriStateCheckbox(
                                        title: category.displayName,
                                        identifier: "run-tools-category-\(category.rawValue)",
                                        state: viewModel.categorySelectionState(category),
                                        enabled: !viewModel.toolPermissionUpdateInFlight
                                    ) {
                                        viewModel.setCategory(
                                            category,
                                            selected: viewModel.categorySelectionState(category) != .checked
                                        )
                                    }
                                    .frame(minWidth: 240, alignment: .leading)

                                    ForEach(viewModel.filteredToolEntries.filter {
                                        $0.category == category
                                    }) { tool in
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                NativeTriStateCheckbox(
                                                    title: tool.displayName,
                                                    identifier: "run-tool-\(tool.id)",
                                                    state: viewModel.isToolSelected(tool.id)
                                                        ? .checked
                                                        : .unchecked,
                                                    enabled: !viewModel.toolPermissionUpdateInFlight
                                                        && (tool.available
                                                            || permissions.selectedToolIDs.contains(tool.id))
                                                ) {
                                                    viewModel.setTool(
                                                        tool.id,
                                                        selected: !viewModel.isToolSelected(tool.id)
                                                    )
                                                }
                                                .frame(minWidth: 180, alignment: .leading)
                                                if tool.highImpact {
                                                    Text("Higher impact")
                                                        .font(.caption2)
                                                        .foregroundStyle(.orange)
                                                }
                                            }
                                            Text(tool.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(tool.id)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.tertiary)
                                            if let reason = tool.unavailableReason {
                                                Text(reason)
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .padding(.leading, 20)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the registered capability catalog for this project…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("run-tools-loading")
            }
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
            showingAdvancedOverrides = true
            viewModel.refreshPreparationRecovery()
        }
    }
}

private struct NativeTriStateCheckbox: NSViewRepresentable {
    let title: String
    let identifier: String
    let state: ToolCheckboxState
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NativeCheckboxButton {
        NativeCheckboxButton(
            title: title,
            identifier: identifier,
            activation: action
        )
    }

    func updateNSView(_ button: NativeCheckboxButton, context: Context) {
        button.activation = action
        button.title = title
        button.setAccessibilityIdentifier(identifier)
        if !enabled, button.window?.firstResponder === button {
            button.restoreKeyboardFocusWhenEnabled = true
        }
        button.isEnabled = enabled
        if enabled, button.restoreKeyboardFocusWhenEnabled {
            button.restoreKeyboardFocusWhenEnabled = false
            DispatchQueue.main.async { [weak button] in
                guard let button, button.isEnabled else { return }
                button.window?.makeFirstResponder(button)
            }
        }
        switch state {
        case .unchecked: button.state = .off
        case .mixed: button.state = .mixed
        case .checked: button.state = .on
        }
    }
}

private final class NativeCheckboxButton: NSButton {
    var activation: () -> Void
    var restoreKeyboardFocusWhenEnabled = false

    init(title: String, identifier: String, activation: @escaping () -> Void) {
        self.activation = activation
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        allowsMixedState = true
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        activation()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        state = state == .on ? .off : .on
        activation()
    }
}
