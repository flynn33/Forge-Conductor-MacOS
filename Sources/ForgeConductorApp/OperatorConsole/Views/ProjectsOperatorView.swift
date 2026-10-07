// ProjectsOperatorView.swift
// Native project source list and manager-owned registration/reset controls.

import AppKit
import SwiftUI

struct ProjectsOperatorView: View {
    @EnvironmentObject private var guidedMode: GuidedModeCoordinator
    @StateObject private var viewModel: ProjectsViewModel
    @State private var registrationDraft: ProjectRegistrationDraft?
    @State private var registrationHelpToken: GuidedModeCoordinator.ContextToken?
    @State private var registrationPickerErrorMessage: String?
    @State private var resetConfirmation: ProjectsViewModel.ResetConfirmation?
    @State private var removeConfirmation: ProjectsViewModel.RemoveConfirmation?
    @State private var clearConfirmation: ProjectsViewModel.ClearConfirmation?
    @State private var clearMode: OperatorProjectContentClearMode = .memory
    @State private var showClearCacheConfirmation = false
    @State private var expandedInstructionPackageIDs: Set<String> = []

    init(
        client: any OperatorManagerClientProtocol,
        onOpenProvider: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: ProjectsViewModel(client: client))
        _ = onOpenProvider
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Registered projects")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(viewModel.projects.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(GraphitePalette.textSecondary)
                }
                .padding(16)
                if viewModel.projects.isEmpty {
                    VStack(spacing: 10) {
                        if viewModel.isLoading {
                            ProgressView("Loading projects…")
                        } else {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 28))
                                .foregroundStyle(GraphitePalette.info)
                            Text(viewModel.errorMessage == nil ? "No registered projects" : "Projects unavailable")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Add project folders or enter an absolute project path below.")
                                .font(.system(size: 12))
                                .foregroundStyle(GraphitePalette.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("projects-empty-sidebar")
                } else {
                    List(selection: $viewModel.selectedProjectID) {
                        ForEach(viewModel.projects) { project in
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(GraphitePalette.info)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.displayName).lineLimit(1)
                                    Text("Generation \(project.projectGeneration) · \(project.lifecycleState)")
                                        .font(.caption)
                                        .foregroundStyle(GraphitePalette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(project.projectID)
                            .accessibilityIdentifier("project-row-\(project.projectID)")
                            .contextMenu {
                                Button("Remove Project…", role: .destructive) {
                                    viewModel.selectedProjectID = project.projectID
                                    requestSelectedProjectRemoval()
                                }
                                .disabled(viewModel.isLoading || project.lifecycleState != "active")
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                Divider()
                VStack(spacing: 8) {
                    Button {
                        chooseProjectFolder()
                    } label: {
                        Label("Add Project Folders…", systemImage: "plus")
                            .frame(width: 196, height: 20)
                    }
                    .buttonStyle(GraphiteButtonStyle(kind: .primary))
                    .accessibilityIdentifier("project-register")
                    Button {
                        registrationDraft = ProjectRegistrationDraft(
                            path: "", name: "", allowsPathEntry: true
                        )
                    } label: {
                        Text("Enter Project Path…")
                            .frame(width: 196, height: 20)
                    }
                    .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("project-register-by-path")
                    Button(role: .destructive) {
                        requestSelectedProjectRemoval()
                    } label: {
                        Label("Remove Selected Project…", systemImage: "minus")
                            .frame(width: 196, height: 20)
                    }
                    .buttonStyle(GraphiteButtonStyle(kind: .destructive))
                    .disabled(
                        viewModel.isLoading
                            || viewModel.selectedProject?.lifecycleState != "active"
                    )
                    .help("Remove the selected registration while preserving durable memory and history.")
                    .accessibilityIdentifier("project-remove-sidebar")
                }
                .padding(10)
            }
            .background(GraphitePalette.sidebar)
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OperatorHeader(
                        title: "Projects",
                        subtitle: "Durable identity, generation, bindings, memory, and continuity",
                        isLoading: viewModel.isLoading,
                        titleAccessibilityIdentifier: "detail-projects",
                        subtitleAccessibilityIdentifier: "projects-operator-view",
                        onRefresh: viewModel.load
                    )
                    if let error = viewModel.errorMessage {
                        OperatorErrorBanner(message: error, retry: viewModel.load)
                    }
                    if let error = registrationPickerErrorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(GraphitePalette.textSecondary)
                            .accessibilityIdentifier("project-picker-error")
                    }
                    if let notice = viewModel.notice {
                        OperatorNoticeBanner(message: notice)
                    }
                    if viewModel.selectedProject == nil {
                        projectWorkflowActions
                    }
                    if let pendingPath = viewModel.pendingRegistrationPath {
                        GroupBox("Registration reconciliation") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    viewModel.pendingRegistrationProjectID == nil
                                        ? "Both bounded registration attempts lost their response. The outcome is unknown; replaying the exact request is idempotent."
                                        : "The manager retained this exact registration after a partial transition. When its project is in maintenance, normal work remains fenced. The request is reconstructed after restart."
                                )
                                .font(.system(size: 13))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(GraphitePalette.textSecondary)
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
                                        .font(.system(size: 13))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .foregroundStyle(GraphitePalette.textSecondary)
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
                        GroupBox("Instruction packages") {
                            Text("Select or add a project to add, reorder, and delete instruction packages.")
                                .font(.caption)
                                .foregroundStyle(GraphitePalette.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        }
                        .accessibilityIdentifier("project-instruction-packages")
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
        .background(GraphitePalette.canvas)
        .sheet(item: $registrationDraft, onDismiss: releaseRegistrationHelpContext) { draft in
            ProjectRegistrationSheet(draft: draft, viewModel: viewModel)
                .guidedHelpContext(.projectRegistration, ownerToken: $registrationHelpToken)
        }
        .alert(
            "Remove project from Forge Conductor?",
            isPresented: Binding(
                get: { removeConfirmation != nil },
                set: { if !$0 { removeConfirmation = nil } }
            ),
            presenting: removeConfirmation
        ) { confirmation in
            Button("Cancel", role: .cancel) {}
            Button("Remove Project", role: .destructive) {
                removeConfirmation = nil
                viewModel.removeProject(confirmation)
            }
        } message: { confirmation in
            Text("\(confirmation.displayName)\n\(confirmation.projectID)\nThis removes the registration from the Projects tab and fences generation \(confirmation.generation). Durable project memory and historical evidence are preserved. Registering the same repository again reconnects it.")
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
        .alert("Clear Forge application cache?", isPresented: $showClearCacheConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                viewModel.clearApplicationCache()
            }
        } message: {
            Text("This removes disposable Forge cache files only. Project files, instruction packages, continuity, policy logs, settings, and credentials remain.")
        }
        .task { viewModel.load() }
        .task(id: viewModel.selectedProjectID) {
            while !Task.isCancelled {
                viewModel.loadInstructionQueue()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func projectDetail(_ project: OperatorProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GraphitePanel {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(GraphitePalette.info)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(project.displayName)
                            .font(.system(size: 20, weight: .semibold))
                        OperatorIdentifier(project.canonicalRoot)
                            .accessibilityIdentifier("project-canonical-root")
                        HStack(spacing: 16) {
                            Text("Generation \(project.projectGeneration)")
                                .font(.system(size: 12))
                                .foregroundStyle(GraphitePalette.textSecondary)
                                .accessibilityIdentifier("project-generation")
                            OperatorStateBadge(state: project.lifecycleState)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            projectWorkflowActions
            instructionPackages(project)

            GroupBox("Identity") {
                LabeledContent("Project UUID") { OperatorIdentifier(project.projectID) }
            }

            ProjectRepositoryEditor(project: project, viewModel: viewModel)
                .id("\(project.projectID):\(project.projectGeneration)")

            GroupBox("Active bindings") {
                if project.bindings.isEmpty {
                    Text("No active binding records were published.")
                        .foregroundStyle(GraphitePalette.textSecondary)
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
                        if let detail = memory.detail { Text(detail).font(.caption).foregroundStyle(GraphitePalette.textSecondary) }
                    }
                } else {
                    Text("Memory database health was not published by this manager.")
                        .foregroundStyle(GraphitePalette.textSecondary)
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
                        .foregroundStyle(GraphitePalette.textSecondary)
                }
            }

            if !project.migrationWarnings.isEmpty {
                GroupBox("Migration and quarantine warnings") {
                    ForEach(project.migrationWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(GraphitePalette.warning)
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
                GraphitePanel {
                    HStack {
                        Text("Relink reconciliation").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        GuidedHelpButton(context: .projectRelink)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "The last relink did not return a confirmed receipt. "
                                + "Replaying the exact project, generation, and path is idempotent "
                                + "and lets the manager reconcile a commit whose response was lost."
                        )
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(GraphitePalette.textSecondary)
                        LabeledContent("Pending path") {
                            OperatorIdentifier(pendingPath)
                        }
                        HStack {
                            Button("Reconcile Relink") {
                                viewModel.reconcilePendingRelink()
                            }
                            .buttonStyle(GraphiteButtonStyle(kind: .primary))
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

            GraphitePanel {
                HStack {
                    Text("Clear project content").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    GuidedHelpButton(context: .projectContentClear)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Scope", selection: $clearMode) {
                        ForEach(OperatorProjectContentClearMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("project-clear-mode")
                    Text(clearMode.effectDescription)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(GraphitePalette.textSecondary)
                    Text("Clearing removes selected content from active application retrieval. SQLite pages, backups, and snapshots are governed by their separate retention policy; this is not secure physical erasure.")
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(GraphitePalette.textSecondary)
                    HStack {
                        Button("Clear \(clearMode.title)…", role: .destructive) {
                            clearConfirmation = viewModel.clearConfirmationForSelectedProject(
                                mode: clearMode
                            )
                        }
                        .buttonStyle(GraphiteButtonStyle(kind: .destructive))
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
                Button("Remove Project…", role: .destructive) {
                    requestSelectedProjectRemoval()
                }
                .buttonStyle(GraphiteButtonStyle(kind: .destructive))
                .disabled(viewModel.isLoading || project.lifecycleState != "active")
                .accessibilityIdentifier("project-remove")
                Button("Relink…") {
                    chooseRelinkFolder(for: project)
                }
                .disabled(viewModel.isLoading || project.lifecycleState != "active")
                .help("Choose another location for this same Git repository.")
                .accessibilityIdentifier("project-relink")
                GuidedHelpButton(context: .projectRelink)
            }
        }
    }

    private var projectWorkflowActions: some View {
        GroupBox("Project workflow") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { projectWorkflowButtons }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) { projectWorkflowButtons }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("project-workflow-actions")
    }

    @ViewBuilder
    private var projectWorkflowButtons: some View {
        Button {
            chooseProjectFolder()
        } label: {
            Label("Add Project Folders…", systemImage: "plus")
                .frame(width: 196, height: 20)
        }
        .buttonStyle(GraphiteButtonStyle(kind: .primary))
        .accessibilityIdentifier("project-register-primary")

        Button {
            chooseInstructionPackage()
        } label: {
            Label("Add Instructions…", systemImage: "doc.badge.plus")
                .frame(width: 196, height: 20)
        }
        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
        .disabled(viewModel.isLoading || viewModel.selectedProject?.lifecycleState != "active")
        .accessibilityIdentifier("instruction-package-add-primary")

        Button(role: .destructive) {
            resetConfirmation = viewModel.resetConfirmationForSelectedProject()
        } label: {
            Text("Reset Generation…")
                .frame(width: 196, height: 20)
        }
        .buttonStyle(GraphiteButtonStyle(kind: .destructive))
        .disabled(viewModel.isLoading || viewModel.selectedProject == nil)
        .accessibilityIdentifier("project-reset")

        Button(role: .destructive) {
            showClearCacheConfirmation = true
        } label: {
            Text("Clear Cache…")
                .frame(width: 196, height: 20)
        }
        .buttonStyle(GraphiteButtonStyle(kind: .destructive))
        .disabled(viewModel.isLoading)
        .help("Removes disposable Forge cache files without deleting project or continuity data.")
        .accessibilityIdentifier("project-clear-cache")
    }

    private func requestSelectedProjectRemoval() {
        removeConfirmation = viewModel.removeConfirmationForSelectedProject()
    }

    @ViewBuilder
    private func instructionPackages(_ project: OperatorProject) -> some View {
        GraphitePanel {
            HStack {
                Text("Instruction packages").font(.system(size: 15, weight: .semibold))
                Spacer()
                GuidedHelpButton(context: .instructionQueue)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Add files, folders, or ZIPs in their existing format. Forge preserves every source, converts supported instruction content into immutable project-scoped artifacts, and reports anything it cannot interpret. Drag packages to set their priority; the top package has highest priority.")
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(GraphitePalette.textSecondary)

                if let queue = viewModel.instructionQueue {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Add Instructions…", systemImage: "plus") {
                                chooseInstructionPackage()
                            }
                            .buttonStyle(GraphiteButtonStyle(kind: .primary))
                            .disabled(viewModel.isLoading)
                            .accessibilityIdentifier("instruction-package-add")
                            GuidedHelpButton(context: .instructionImport)
                            Spacer()
                            Text("\(queue.packages.count) package\(queue.packages.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(GraphitePalette.textSecondary)
                        }
                    }

                    if queue.packages.isEmpty {
                        ContentUnavailableView(
                            "No Instruction Packages",
                            systemImage: "list.number",
                            description: Text("Add package instructions for this repository, then arrange their execution order.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                Text("Priority").frame(width: 48, alignment: .leading)
                                Text("Instruction package").frame(maxWidth: .infinity, alignment: .leading)
                                Text("State").frame(width: 104, alignment: .trailing)
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(GraphitePalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(GraphitePalette.field)
                            ForEach(queue.packages) { package in
                                instructionPackageRow(package, packages: queue.packages)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(package.state == "running" ? GraphitePalette.panelRaised : GraphitePalette.panelBottom)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(GraphitePalette.separator).frame(height: 1)
                                    }
                                    .draggable(package.id)
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let draggedPackageID = items.first else { return false }
                                        viewModel.moveInstructionPackage(
                                            draggedPackageID,
                                            to: package.id
                                        )
                                        return draggedPackageID != package.id
                                    }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(GraphitePalette.separator, lineWidth: 1)
                        }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading instruction packages…")
                            .foregroundStyle(GraphitePalette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("project-instruction-packages")
    }

    @ViewBuilder
    private func instructionPackageRow(
        _ package: OperatorInstructionPackage,
        packages: [OperatorInstructionPackage]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(package.position + 1)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(package.displayName)
                            .fontWeight(.medium)
                            .accessibilityIdentifier("instruction-package-row-\(package.id)")
                        if package.state == "running" {
                            Label("Current", systemImage: "play.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(GraphitePalette.primaryFill)
                        }
                    }
                    Text("\(package.packageID) · v\(package.version)")
                        .font(.caption)
                        .foregroundStyle(GraphitePalette.textSecondary)
                    if let count = package.documentCount,
                       let bytes = package.instructionByteCount {
                        Text("\(count) source file\(count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) converted instructions")
                            .font(.caption)
                            .foregroundStyle(GraphitePalette.textSecondary)
                    }
                    if let unresolved = package.unresolvedDocumentCount,
                       unresolved > 0 {
                        Label(
                            "\(unresolved) unresolved source file\(unresolved == 1 ? "" : "s") retained in the immutable snapshot",
                            systemImage: "doc.badge.ellipsis"
                        )
                        .font(.caption)
                        .foregroundStyle(package.importReady == false ? GraphitePalette.warning : GraphitePalette.textSecondary)
                    }
                    if let error = package.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(GraphitePalette.failure)
                            .lineLimit(2)
                    }
                }
                Spacer()
                OperatorStateBadge(state: package.state)
                    .frame(width: 104, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.moveInstructionPackage(package.id, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                .controlSize(.small)
                .disabled(
                    viewModel.isLoading || packages.first?.id == package.id
                )
                .help("Move this instruction package earlier")
                .accessibilityLabel("Move \(package.displayName) earlier")
                .accessibilityIdentifier("instruction-package-move-up-\(package.id)")
                Button {
                    viewModel.moveInstructionPackage(package.id, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                .controlSize(.small)
                .disabled(
                    viewModel.isLoading || packages.last?.id == package.id
                )
                .help("Move this instruction package later")
                .accessibilityLabel("Move \(package.displayName) later")
                .accessibilityIdentifier("instruction-package-move-down-\(package.id)")
                Button("Delete Package", role: .destructive) {
                    viewModel.removeInstructionPackage(package.id)
                }
                .buttonStyle(GraphiteButtonStyle(kind: .destructive))
                .controlSize(.small)
                .disabled(viewModel.isLoading || package.state == "running")
                .help("Delete this instruction package from the project")
                .accessibilityIdentifier("instruction-package-remove-\(package.id)")
                Spacer()
            }

            Button {
                if expandedInstructionPackageIDs.contains(package.id) {
                    expandedInstructionPackageIDs.remove(package.id)
                } else {
                    expandedInstructionPackageIDs.insert(package.id)
                    viewModel.loadInstructionCatalog(for: package)
                }
            } label: {
                Label(
                    expandedInstructionPackageIDs.contains(package.id)
                        ? "Hide file catalog" : "Show file catalog",
                    systemImage: expandedInstructionPackageIDs.contains(package.id)
                        ? "chevron.down" : "chevron.right"
                )
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("instruction-package-catalog-toggle-\(package.id)")

            if expandedInstructionPackageIDs.contains(package.id) {
                instructionCatalog(package)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func instructionCatalog(_ package: OperatorInstructionPackage) -> some View {
        if viewModel.loadingInstructionCatalogs.contains(package.id) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading every retained source file…")
                    .foregroundStyle(GraphitePalette.textSecondary)
            }
        } else if let error = viewModel.instructionCatalogError(for: package.id) {
            VStack(alignment: .leading, spacing: 5) {
                Text(error).foregroundStyle(GraphitePalette.failure)
                Button("Retry catalog") {
                    viewModel.loadInstructionCatalog(for: package)
                }
            }
            .font(.caption)
        } else if let catalog = viewModel.instructionCatalog(for: package.id) {
            VStack(alignment: .leading, spacing: 6) {
                Text("File catalog · \(catalog.documents.count) of \(catalog.totalDocuments) retained")
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("instruction-document-catalog-\(package.id)")
                ForEach(catalog.documents) { document in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: document.catalogStatus == "Converted"
                            ? "doc.text.fill"
                            : document.catalogStatus == "Retained attachment"
                                ? "paperclip" : "questionmark.diamond")
                            .foregroundStyle(document.catalogStatus == "Unresolved" ? GraphitePalette.warning : GraphitePalette.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.sourcePath)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text("\(document.catalogStatus) · \(ByteCountFormatter.string(fromByteCount: Int64(document.originalBytes), countStyle: .file))")
                                .foregroundStyle(document.catalogStatus == "Unresolved" ? GraphitePalette.warning : GraphitePalette.textSecondary)
                            if !document.detail.isEmpty {
                                Text(document.detail)
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("instruction-document-\(document.id)")
                }
            }
            .padding(.leading, 28)
        } else {
            Text("Catalog unavailable")
                .font(.caption)
                .foregroundStyle(GraphitePalette.textSecondary)
        }
    }

    private func releaseRegistrationHelpContext() {
        guard let token = registrationHelpToken else { return }
        guidedMode.pop(token)
        registrationHelpToken = nil
    }

    private func chooseInstructionPackage() {
        let environment = ProcessInfo.processInfo.environment
        if CommandLine.arguments.contains("--uitesting"),
           let path = environment["FORGE_INSTRUCTION_PACKAGE_UI_TEST_SELECTION"] {
            viewModel.importInstructionPackage(path: path)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Instructions"
        panel.message = "Choose an instruction file, folder, or ZIP. Forge preserves the originals and reports unsupported content without executing imported files."
        guard panel.runModal() == .OK else { return }
        let paths: [String] = panel.urls.compactMap { url -> String? in
            guard url.isFileURL, (url.path as NSString).isAbsolutePath else { return nil }
            return url.path
        }
        viewModel.importInstructionPackages(paths: paths)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Projects"
        guard panel.runModal() == .OK else { return }
        let paths: [String] = panel.urls.compactMap { url -> String? in
            guard url.isFileURL, (url.path as NSString).isAbsolutePath else { return nil }
            return url.path
        }
        guard !paths.isEmpty else {
            registrationPickerErrorMessage = "The folder picker did not return an absolute project path. Use Enter Project Path… to register the folder."
            return
        }
        registrationPickerErrorMessage = nil
        viewModel.register(paths: paths)
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

private struct ProjectRepositoryEditor: View {
    let project: OperatorProject
    @ObservedObject var viewModel: ProjectsViewModel
    @State private var location: String

    init(project: OperatorProject, viewModel: ProjectsViewModel) {
        self.project = project
        self.viewModel = viewModel
        _location = State(initialValue: project.githubRepositoryURL ?? "")
    }

    var body: some View {
        GroupBox("GitHub repository") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("https://github.com/owner/repository", text: $location)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("GitHub repository location")
                    .accessibilityIdentifier("project-github-repository-location")
                    .onSubmit(save)
                Text("Link this project's GitHub repository using an HTTPS URL or GitHub SSH clone location.")
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
                HStack {
                    Button("Save Repository", action: save)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("project-github-repository-save")
                    Button("Clear Repository") {
                        viewModel.saveGitHubRepository(
                            projectID: project.projectID,
                            generation: project.projectGeneration,
                            location: nil
                        )
                    }
                    .disabled(project.githubRepositoryURL == nil)
                    .accessibilityIdentifier("project-github-repository-clear")
                    if let url = project.githubRepositoryURL.flatMap(URL.init(string:)) {
                        Link("Open on GitHub", destination: url)
                            .accessibilityIdentifier("project-github-repository-open")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(viewModel.isLoading || project.lifecycleState != "active")
        }
        .onChange(of: project.githubRepositoryURL) { _, url in location = url ?? "" }
        .accessibilityIdentifier("project-github-repository")
    }

    private func save() {
        viewModel.saveGitHubRepository(
            projectID: project.projectID,
            generation: project.projectGeneration,
            location: location
        )
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
            HStack {
                Text("Register Project").font(.title2.bold())
                Spacer()
                GuidedHelpButton(context: .projectRegistration)
            }
            Text("Registration records this exact folder, resolves its canonical root, and creates or reconnects the manager-owned project identity. It does not limit native filesystem access.")
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(GraphitePalette.textSecondary)
            if allowsPathEntry {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Project folder (absolute path)")
                        .font(.system(size: 13, weight: .medium))
                    TextField("Project folder (absolute path)", text: $path)
                        .textFieldStyle(GraphiteFieldStyle())
                        .accessibilityIdentifier("project-register-path")
                }
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
                    .font(.system(size: 13))
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .accessibilityIdentifier("project-register-waiting-for-manager")
            }
            Text("Forge preserves existing selected folders, adds only this folder, resolves its canonical Git repository identity, and checks it before registration.")
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(GraphitePalette.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Display name (optional)")
                    .font(.system(size: 13, weight: .medium))
                TextField("Display name (optional)", text: $name)
                    .textFieldStyle(GraphiteFieldStyle())
                    .accessibilityIdentifier("project-register-name")
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Register") {
                    viewModel.register(path: path, displayName: name)
                    dismiss()
                }
                .buttonStyle(GraphiteButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!(path as NSString).isAbsolutePath || viewModel.isLoading)
                .accessibilityIdentifier("project-register-confirm")
            }
        }
        .padding(22)
        .frame(width: 520)
        .multilineTextAlignment(.leading)
        .background(GraphitePalette.canvas)
    }
}
