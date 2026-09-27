// ContinuityOperatorView.swift
// Project continuity identities only. Continuity execution remains automatic.

import AppKit
import ForgeConductorCore
import SwiftUI

struct ContinuityOperatorView: View {
    @StateObject private var viewModel: ContinuityViewModel
    @State private var confirmsDeletion = false

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ContinuityViewModel(client: client))
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

                actions
                projectList
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { viewModel.load() }
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
        HStack(spacing: 10) {
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

            if let projectID = viewModel.deletingProjectID {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Deleting continuity data for project \(projectID)")
            }

            Spacer()
        }
    }
}
