// ProjectsOperatorView.swift
// Native project source list and manager-owned registration/reset controls.

import AppKit
import SwiftUI

struct ProjectsOperatorView: View {
    @StateObject private var viewModel: ProjectsViewModel
    @State private var registrationDraft: ProjectRegistrationDraft?
    @State private var registrationPickerErrorMessage: String?
    @State private var resetConfirmation: ProjectsViewModel.ResetConfirmation?
    @State private var clearConfirmation: ProjectsViewModel.ClearConfirmation?
    @State private var clearMode: OperatorProjectContentClearMode = .memory

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
                VStack(spacing: 8) {
                    Button("Register Project…", systemImage: "plus") {
                        chooseProjectFolder()
                    }
                    .accessibilityIdentifier("project-register")
                    Button("Enter Project Path…") {
                        registrationDraft = ProjectRegistrationDraft(
                            path: "", name: "", allowsPathEntry: true
                        )
                    }
                    .accessibilityIdentifier("project-register-by-path")
                }
                .padding(10)
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
                    if let error = registrationPickerErrorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("project-picker-error")
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
        .sheet(item: $registrationDraft) { draft in
            ProjectRegistrationSheet(draft: draft, viewModel: viewModel)
        }
        .alert(
            "Reset project generation?",
            isPresented: Binding(
                get: { resetConfirmation != nil },
                set: { if !$0 { resetConfirmation = nil } }
            ),
            presenting: resetConfirmation
        ) { confirmation in
            Button("Cancel", role: .cancel) {}
            Button("Reset and Fence Active Work", role: .destructive) {
                resetConfirmation = nil
                viewModel.resetProject(confirmation)
            }
        } message: { confirmation in
            Text("\(confirmation.displayName)\n\(confirmation.projectID)\nGeneration \(confirmation.generation) will be replaced. Active bindings and in-flight work for this generation will be fenced, and the project memory store will be closed by the manager. Durable memory records persist; only the confirmed project is affected.")
        }
        .alert(
            "Clear selected project content?",
            isPresented: Binding(
                get: { clearConfirmation != nil },
                set: { if !$0 { clearConfirmation = nil } }
            ),
            presenting: clearConfirmation
        ) { confirmation in
            Button("Cancel", role: .cancel) {}
            Button("Clear \(confirmation.mode.title)", role: .destructive) {
                clearConfirmation = nil
                viewModel.clearProjectContent(confirmation)
            }
        } message: { confirmation in
            Text("\(confirmation.displayName)\n\(confirmation.projectID)\nGeneration \(confirmation.generation)\n\(confirmation.mode.effectDescription) This removes content from active retrieval, not secure physical storage. Minimal recovery metadata is retained.")
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

            GroupBox("Clear project content") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Scope", selection: $clearMode) {
                        ForEach(OperatorProjectContentClearMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("project-clear-mode")
                    Text(clearMode.effectDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Clearing removes selected content from active application retrieval. SQLite pages, backups, and snapshots are governed by their separate retention policy; this is not secure physical erasure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Clear \(clearMode.title)…", role: .destructive) {
                            clearConfirmation = viewModel.clearConfirmationForSelectedProject(
                                mode: clearMode
                            )
                        }
                        .disabled(viewModel.isLoading || project.lifecycleState != "active")
                        .accessibilityIdentifier("project-clear-content")
                        if viewModel.pendingClearConfirmation?.projectID.caseInsensitiveCompare(
                            project.projectID
                        ) == .orderedSame {
                            Button("Reconcile Pending Clear") {
                                viewModel.reconcilePendingContentClear()
                            }
                            .disabled(viewModel.isLoading)
                            .accessibilityIdentifier("project-clear-reconcile")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    resetConfirmation = viewModel.resetConfirmationForSelectedProject()
                }
                .disabled(viewModel.isLoading)
                .accessibilityIdentifier("project-reset")
            }
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        guard panel.runModal() == .OK else { return }
        guard let url = panel.urls.first, url.isFileURL,
              (url.path as NSString).isAbsolutePath else {
            registrationPickerErrorMessage = "The folder picker did not return an absolute project path. Use Enter Project Path… to register the folder."
            return
        }
        registrationPickerErrorMessage = nil
        registrationDraft = ProjectRegistrationDraft(
            path: url.path, name: url.lastPathComponent, allowsPathEntry: false
        )
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
        guard panel.runModal() == .OK, let url = panel.urls.first,
              url.isFileURL, (url.path as NSString).isAbsolutePath else { return }
        viewModel.relinkSelectedProject(to: url.path)
    }
}

private struct ProjectRegistrationDraft: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let allowsPathEntry: Bool
}

private struct ProjectRegistrationSheet: View {
    @ObservedObject var viewModel: ProjectsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var name: String
    private let allowsPathEntry: Bool

    init(draft: ProjectRegistrationDraft, viewModel: ProjectsViewModel) {
        self.viewModel = viewModel
        allowsPathEntry = draft.allowsPathEntry
        _path = State(initialValue: draft.path)
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Register Project").font(.title2.bold())
            Text("Registration resolves a canonical root and creates or reconnects the manager-owned project identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if allowsPathEntry {
                TextField("Project folder (absolute path)", text: $path)
                    .accessibilityIdentifier("project-register-path")
            } else {
                LabeledContent("Folder") {
                    Text(path)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("project-register-selected-path")
                }
            }
            if viewModel.isLoading {
                Text("Waiting for the manager to finish refreshing projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("project-register-waiting-for-manager")
            }
            Text("Forge resolves the canonical Git repository identity and checks the folder before registration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Display name (optional)", text: $name)
                .accessibilityIdentifier("project-register-name")
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Register") {
                    viewModel.register(path: path, displayName: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(path as NSString).isAbsolutePath || viewModel.isLoading)
                .accessibilityIdentifier("project-register-confirm")
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
