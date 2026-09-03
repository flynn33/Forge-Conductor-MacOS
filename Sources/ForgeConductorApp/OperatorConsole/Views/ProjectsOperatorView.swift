// ProjectsOperatorView.swift
// Native project source list and manager-owned registration/reset controls.

import AppKit
import SwiftUI

struct ProjectsOperatorView: View {
    @StateObject private var viewModel: ProjectsViewModel
    @State private var showingRegistration = false
    @State private var registrationPath = ""
    @State private var registrationName = ""
    @State private var showingResetConfirmation = false

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ProjectsViewModel(client: client))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedProjectID) {
                ForEach(viewModel.projects) { project in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.displayName).lineLimit(1)
                            Text("Generation \(project.projectGeneration) · \(project.lifecycleState)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(project.projectID)
                    .accessibilityIdentifier("project-row-\(project.projectID)")
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Button("Register Project…", systemImage: "plus") {
                    chooseProjectFolder()
                }
                .padding(10)
                .accessibilityIdentifier("project-register")
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OperatorHeader(
                        title: "Projects",
                        subtitle: "Durable identity, generation, bindings, memory, and continuity",
                        isLoading: viewModel.isLoading,
                        onRefresh: viewModel.load
                    )
                    if let error = viewModel.errorMessage {
                        OperatorErrorBanner(message: error, retry: viewModel.load)
                    }
                    if let notice = viewModel.notice {
                        OperatorNoticeBanner(message: notice)
                    }
                    if let pendingPath = viewModel.pendingRegistrationPath {
                        GroupBox("Registration reconciliation") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    viewModel.pendingRegistrationProjectID == nil
                                        ? "Both bounded registration attempts lost their response. The outcome is unknown; replaying the exact request is idempotent."
                                        : "The manager retained this exact registration after a partial transition. When its project is in maintenance, normal work remains fenced. The request is reconstructed after restart."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                LabeledContent("Pending path") {
                                    OperatorIdentifier(pendingPath)
                                }
                                if let projectID = viewModel.pendingRegistrationProjectID {
                                    LabeledContent("Project UUID") {
                                        OperatorIdentifier(projectID)
                                    }
                                }
                                if let message = viewModel.pendingRegistrationMessage {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Reconcile Registration") {
                                        viewModel.reconcilePendingRegistration()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(viewModel.isLoading)
                                    .accessibilityIdentifier("project-registration-reconcile")
                                    if viewModel.canDiscardPendingRegistration {
                                        Button("Dismiss") {
                                            viewModel.discardPendingRegistration()
                                        }
                                        .disabled(viewModel.isLoading)
                                        .accessibilityIdentifier(
                                            "project-registration-reconcile-dismiss"
                                        )
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("project-registration-reconciliation")
                    }
                    if let project = viewModel.selectedProject {
                        projectDetail(project)
                    } else if viewModel.errorMessage == nil, !viewModel.isLoading {
                        ContentUnavailableView(
                            "No Registered Projects",
                            systemImage: "folder.badge.questionmark",
                            description: Text("Register a project through the manager to establish its durable identity.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(20)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingRegistration) {
            registrationSheet
        }
        .alert(
            "Reset project generation?",
            isPresented: $showingResetConfirmation,
            presenting: viewModel.selectedProject
        ) { _ in
            Button("Cancel", role: .cancel) {}
            Button("Reset and Fence Active Work", role: .destructive) {
                viewModel.resetSelectedProject()
            }
        } message: { project in
            Text("\(project.displayName)\n\(project.projectID)\nGeneration \(project.projectGeneration) will be replaced. Active bindings and in-flight work for this generation will be fenced by the manager.")
        }
        .task { viewModel.load() }
        .accessibilityIdentifier("projects-operator-view")
    }

    private func projectDetail(_ project: OperatorProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Identity") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Name", value: project.displayName)
                    LabeledContent("Project UUID") { OperatorIdentifier(project.projectID) }
                    LabeledContent("Canonical root") {
                        OperatorIdentifier(project.canonicalRoot)
                            .accessibilityIdentifier("project-canonical-root")
                    }
                    LabeledContent("Generation", value: "\(project.projectGeneration)")
                        .accessibilityIdentifier("project-generation")
                    LabeledContent("Lifecycle") { OperatorStateBadge(state: project.lifecycleState) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Active bindings") {
                if project.bindings.isEmpty {
                    Text("No active binding records were published.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(project.bindings) { binding in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(binding.ownerKind.replacingOccurrences(of: "_", with: " "))
                                OperatorIdentifier(binding.ownerID)
                            }
                            Spacer()
                            OperatorStateBadge(state: binding.active ? "active" : "inactive")
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            GroupBox("Project memory") {
                if let memory = project.memory {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Health") { OperatorStateBadge(state: memory.state) }
                        LabeledContent("Database size", value: OperatorFormat.bytes(memory.databaseBytes))
                        LabeledContent("Records", value: OperatorFormat.integer(memory.recordCount))
                        LabeledContent("Last integrity check", value: memory.lastIntegrityCheck ?? "Unavailable")
                        if let detail = memory.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    Text("Memory database health was not published by this manager.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Continuity") {
                if let continuity = project.continuity {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("State") { OperatorStateBadge(state: continuity.state) }
                        LabeledContent("Latest valid handoff") { OperatorIdentifier(continuity.latestHandoffID) }
                        LabeledContent("Handoff checksum") { OperatorIdentifier(continuity.latestHandoffSHA256) }
                        LabeledContent("Migration", value: continuity.migrationState ?? "Unavailable")
                    }
                } else {
                    Text("No project-scoped continuity projection was published.")
                        .foregroundStyle(.secondary)
                }
            }

            if !project.migrationWarnings.isEmpty {
                GroupBox("Migration and quarantine warnings") {
                    ForEach(project.migrationWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("project-migration-warning")
                    }
                }
            }

            if let receipt = project.resetReceipt {
                GroupBox("Latest reset receipt") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Prior generation", value: "\(receipt.priorGeneration)")
                        LabeledContent("New generation", value: "\(receipt.newGeneration)")
                        LabeledContent("Fenced bindings", value: "\(receipt.invalidatedBindingCount)")
                        LabeledContent("Completed", value: receipt.completedAt ?? "Unavailable")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("project-reset-receipt")
            }

            if let pendingPath = viewModel.pendingRelinkPath {
                GroupBox("Relink reconciliation") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "The last relink did not return a confirmed receipt. "
                                + "Replaying the exact project, generation, and path is idempotent "
                                + "and lets the manager reconcile a commit whose response was lost."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        LabeledContent("Pending path") {
                            OperatorIdentifier(pendingPath)
                        }
                        HStack {
                            Button("Reconcile Relink") {
                                viewModel.reconcilePendingRelink()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isLoading)
                            .accessibilityIdentifier("project-relink-reconcile")
                            if viewModel.canDiscardPendingRelink {
                                Button("Dismiss") {
                                    viewModel.discardPendingRelink()
                                }
                                .disabled(viewModel.isLoading)
                                .accessibilityIdentifier("project-relink-reconcile-dismiss")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("project-relink-reconciliation")
            }

            HStack {
                Button("Relink…") {
                    chooseRelinkFolder(for: project)
                }
                .disabled(viewModel.isLoading || project.lifecycleState != "active")
                .help("Choose another location for this same Git repository.")
                .accessibilityIdentifier("project-relink")
                Spacer()
                Button("Reset Generation…", role: .destructive) {
                    showingResetConfirmation = true
                }
                .accessibilityIdentifier("project-reset")
            }
        }
    }

    private var registrationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Register Project").font(.title2.bold())
            Text("Registration resolves a canonical root and creates or reconnects the manager-owned project identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Folder") { OperatorIdentifier(registrationPath) }
            TextField("Display name (optional)", text: $registrationName)
                .accessibilityIdentifier("project-register-name")
            HStack {
                Button("Cancel", role: .cancel) { showingRegistration = false }
                Spacer()
                Button("Register") {
                    viewModel.register(path: registrationPath, displayName: registrationName)
                    showingRegistration = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(registrationPath.isEmpty || viewModel.isLoading)
                .accessibilityIdentifier("project-register-confirm")
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        registrationPath = url.standardizedFileURL.path
        registrationName = url.lastPathComponent
        showingRegistration = true
    }

    /// Uses the native directory picker in production. UI qualification can
    /// supply one explicit selection without trying to automate the system-owned
    /// panel process.
    private func chooseRelinkFolder(for project: OperatorProject) {
        let environment = ProcessInfo.processInfo.environment
        if CommandLine.arguments.contains("--uitesting"),
           let path = environment["FORGE_PROJECT_RELINK_UI_TEST_SELECTION"] {
            viewModel.relinkSelectedProject(to: path)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.canonicalRoot, isDirectory: true)
            .deletingLastPathComponent()
        panel.prompt = "Relink Project"
        panel.message = "Choose the new location of \(project.displayName). Forge Conductor will verify that it is the same Git repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.relinkSelectedProject(to: url.standardizedFileURL.path)
    }
}
