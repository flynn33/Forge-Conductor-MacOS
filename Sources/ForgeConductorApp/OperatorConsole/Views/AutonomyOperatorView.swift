// AutonomyOperatorView.swift
// Native managed-run source list, detail inspector, and duplicate-safe start sheet.

import SwiftUI

struct AutonomyOperatorView: View {
    @StateObject private var viewModel: AutonomyViewModel
    @State private var showingStartSheet = false
    @State private var showingCancelConfirmation = false

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: AutonomyViewModel(client: client))
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
                Button("Start Managed Run…", systemImage: "plus") {
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

            GroupBox("Deterministic completion") {
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
            Text("Start Managed Run").font(.title2.bold())
            Text("The manager persists the run before any provider side effect. Required fields have no hidden UI defaults.")
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
            TextField("Mission", text: $viewModel.mission, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("run-start-mission")
            TextField("Assignment ID (optional)", text: $viewModel.assignmentID)
            HStack {
                TextField("Provider", text: $viewModel.providerID)
                TextField("Adapter", text: $viewModel.adapterID)
            }
            TextField("Model", text: $viewModel.modelKey)
                .accessibilityIdentifier("run-start-model")
            TextField("Allowed tools (comma or newline separated)", text: $viewModel.allowedTools, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("run-start-tool-policy")
            TextField("Completion gates (comma or newline separated)", text: $viewModel.completionGates, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("run-start-completion-gates")
            Toggle("Allow network tools for this run", isOn: $viewModel.networkAllowed)

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
                Button("Start Run") {
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
}
