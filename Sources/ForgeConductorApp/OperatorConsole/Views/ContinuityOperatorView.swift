// ContinuityOperatorView.swift
// Project continuity identities only. Continuity execution remains automatic.

import AppKit
import ForgeConductorCore
import SwiftUI

struct ContinuityOperatorView: View {
    @StateObject private var viewModel: ContinuityViewModel
    @StateObject private var projectActions: ProjectsViewModel
    @State private var confirmsDeletion = false
    @State private var resetConfirmation: ProjectsViewModel.ResetConfirmation?
    @State private var packageToDelete: OperatorInstructionPackage?
    @State private var selectedInstructionPackageID: String?
    @State private var showClearCacheConfirmation = false

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ContinuityViewModel(client: client))
        _projectActions = StateObject(wrappedValue: ProjectsViewModel(client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Continuity")
                    .font(.title2.bold())
                    .accessibilityIdentifier("detail-continuity")
                Text("Automatic continuity by project")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("continuity-operator-view")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let error = viewModel.errorMessage {
                    OperatorErrorBanner(message: error, retry: viewModel.load)
                }
                if let error = viewModel.commandErrorMessage {
                    Label {
                        Text(error)
                            .font(.caption)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("continuity-delete-error")
                }
                if let notice = viewModel.notice {
                    OperatorNoticeBanner(message: notice)
                }
                if let error = projectActions.errorMessage {
                    Label {
                        Text(error)
                            .font(.caption)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("continuity-project-action-error")
                }
                if let notice = projectActions.notice {
                    OperatorNoticeBanner(message: notice)
                }

                actions
                packageActions
                projectList
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            viewModel.load()
            projectActions.load()
        }
        .task(id: viewModel.selectedProjectID) {
            projectActions.selectedProjectID = viewModel.selectedProjectID
            while !Task.isCancelled {
                projectActions.loadInstructionQueue()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
        .onReceive(projectActions.$projects) { _ in
            projectActions.selectedProjectID = viewModel.selectedProjectID
            projectActions.loadInstructionQueue()
        }
        .onReceive(projectActions.$instructionQueue) { queue in
            let packageIDs = queue?.packages.map(\.id) ?? []
            if let selectedInstructionPackageID,
               packageIDs.contains(selectedInstructionPackageID) {
                return
            }
            selectedInstructionPackageID = packageIDs.first
        }
        .guidedHelpState(viewModel.guidedHelpState, for: .continuity)
        .alert("Delete continuity data?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.deleteSelectedProjectContinuity()
            }
        } message: {
            Text(
                "This deletes saved checkpoints, handoffs, transition history, and derived continuity cache for the selected project. It does not delete project files, registration, instruction packages, policies, project memory, or run history."
            )
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
            Button("Reset", role: .destructive) {
                resetConfirmation = nil
                projectActions.resetProject(confirmation)
            }
        } message: { confirmation in
            Text("\(confirmation.displayName)\n\(confirmation.projectID)\nGeneration \(confirmation.generation) will be replaced and active work for that generation will be fenced.")
        }
        .alert(
            "Delete instruction package?",
            isPresented: Binding(
                get: { packageToDelete != nil },
                set: { if !$0 { packageToDelete = nil } }
            ),
            presenting: packageToDelete
        ) { package in
            Button("Cancel", role: .cancel) {}
            Button("Delete Package", role: .destructive) {
                packageToDelete = nil
                projectActions.removeInstructionPackage(package.id)
            }
        } message: { package in
            Text("Delete \(package.displayName) from the selected Continuity project?")
        }
        .alert("Clear Forge application cache?", isPresented: $showClearCacheConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                projectActions.clearApplicationCache()
            }
        } message: {
            Text("This removes disposable Forge cache files only. Project files, instruction packages, continuity, policy logs, settings, and credentials remain.")
        }
    }

    private var projectList: some View {
        List(selection: $viewModel.selectedProjectID) {
            if viewModel.projectIDs.isEmpty, !viewModel.isLoading {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "No continuity projects",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .font(.headline)
                    Text("Project IDs appear here automatically after continuity data is saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                .accessibilityIdentifier("continuity-projects-empty")
            }
            ForEach(viewModel.projectIDs, id: \.self) { projectID in
                Text(projectID)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .tag(String?.some(projectID))
                    .accessibilityIdentifier("continuity-project-row-\(projectID)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("continuity-project-list")
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { projectActionButtons }
            VStack(alignment: .leading, spacing: 8) { projectActionButtons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var projectActionButtons: some View {
        Button("Copy Project ID") {
            guard let projectID = viewModel.selectedProjectID else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(projectID, forType: .string)
        }
        .disabled(viewModel.selectedProjectID == nil)
        .accessibilityIdentifier("continuity-copy-project-id")

        Button("Delete", role: .destructive) {
            confirmsDeletion = true
        }
        .disabled(!viewModel.canDeleteSelectedProject)
        .accessibilityIdentifier("continuity-delete-project")

        Button("Reset", role: .destructive) {
            projectActions.selectedProjectID = viewModel.selectedProjectID
            resetConfirmation = projectActions.resetConfirmationForSelectedProject()
        }
        .disabled(
            viewModel.selectedProjectID == nil
                || projectActions.selectedProject == nil
                || projectActions.isLoading
        )
        .accessibilityIdentifier("continuity-reset")

        Button("Clear Cache", role: .destructive) {
            showClearCacheConfirmation = true
        }
        .disabled(projectActions.isLoading)
        .help("Removes disposable Forge cache files without deleting project or continuity data.")
        .accessibilityIdentifier("continuity-clear-cache")

        if let projectID = viewModel.deletingProjectID {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Deleting continuity data for project \(projectID)")
        }

    }

    private var packageActions: some View {
        GroupBox("Instruction packages for selected project") {
            HStack(spacing: 10) {
                Picker("Package", selection: $selectedInstructionPackageID) {
                    if projectActions.instructionQueue?.packages.isEmpty != false {
                        Text("No instruction packages").tag(String?.none)
                    }
                    ForEach(projectActions.instructionQueue?.packages ?? []) { package in
                        Text(package.displayName).tag(String?.some(package.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)
                .disabled(projectActions.instructionQueue?.packages.isEmpty != false)
                .accessibilityIdentifier("continuity-package-picker")

                Button("Delete Package", role: .destructive) {
                    guard let selectedInstructionPackageID,
                          let package = projectActions.instructionQueue?.packages.first(where: {
                              $0.id == selectedInstructionPackageID
                          }) else { return }
                    packageToDelete = package
                }
                .disabled(
                    projectActions.isLoading
                        || selectedInstructionPackageID == nil
                        || projectActions.instructionQueue?.packages.first(where: {
                            $0.id == selectedInstructionPackageID
                        })?.state == "running"
                )
                .accessibilityIdentifier("continuity-delete-package")

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("continuity-package-actions")
    }
}
