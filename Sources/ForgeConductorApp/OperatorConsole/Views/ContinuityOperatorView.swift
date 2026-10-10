// ContinuityOperatorView.swift
// Project-grouped packet management. Continuity execution remains automatic.

import AppKit
import ForgeConductorCore
import SwiftUI

struct ContinuityOperatorView: View {
    @StateObject private var viewModel: ContinuityViewModel
    @State private var confirmsPacketDeletion = false
    @State private var confirmsReset = false
    @State private var showClearCacheConfirmation = false
    @State private var selectedPacketIDs = Set<String>()

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ContinuityViewModel(client: client))
    }

    var body: some View {
        NativeWorkspaceView(viewID: "continuity", descriptors: NativeWorkspaceCatalog.continuity,
                            defaultContent: { defaultContent }, panelContent: workspacePanel)
        .onAppear {
            selectedPacketIDs = viewModel.selectedPacketIDs
        }
        .onChange(of: selectedPacketIDs) { _, selection in
            guard viewModel.selectedPacketIDs != selection else { return }
            viewModel.selectedPacketIDs = selection
        }
        .onChange(of: viewModel.selectedPacketIDs) { _, selection in
            guard selectedPacketIDs != selection else { return }
            selectedPacketIDs = selection
        }
        .task {
            viewModel.load()
        }
        .task(id: viewModel.selectedProjectID) {
            viewModel.loadPackets()
        }
        .guidedHelpState(viewModel.guidedHelpState, for: .continuity)
        .alert("Delete selected continuity packets?", isPresented: $confirmsPacketDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { viewModel.deleteSelectedPackets() }
        } message: {
            Text(
                "Delete \(viewModel.selectedPacketIDs.count) selected packet"
                    + (viewModel.selectedPacketIDs.count == 1 ? "" : "s")
                    + "? Only those handoff/checkpoint records and their derived projections will be removed."
            )
        }
        .alert("Reset continuity history?", isPresented: $confirmsReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { viewModel.resetSelectedProjectContinuity() }
        } message: {
            Text("This removes settled automatic continuity history for the selected project. It does not advance the project generation, delete project files, or delete durable packets; packets are removed only with Delete.")
        }
        .alert("Clear disposable continuity cache?", isPresented: $showClearCacheConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) { viewModel.clearDisposableCache() }
        } message: {
            Text("This removes disposable Forge cache files only. Project files, continuity packets, instruction packages, policy logs, settings, and credentials remain.")
        }
    }

    private func workspacePanel(_ id: String, _ visible: Bool) -> AnyView {
        switch id {
        case "continuity-controls": AnyView(continuityControls)
        case "continuity-status": AnyView(continuityStatus)
        case "continuity-projects": AnyView(continuityProjects)
        case "continuity-packets": AnyView(continuityPackets)
        default: AnyView(EmptyView())
        }
    }

    private var defaultContent: some View {
        VStack(spacing: 0) {
            continuityHeader

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                continuityStatusContent
                actions
                packetBrowser
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GraphitePalette.canvas)
    }

    @ViewBuilder
    private var continuityHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Continuity")
                .font(.system(size: 24, weight: .bold))
                .accessibilityIdentifier("detail-continuity")
            Text("Automatic continuity packets by project")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(GraphitePalette.textSecondary)
                .accessibilityIdentifier("continuity-operator-view")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var continuityStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            continuityStatusContent
        }
    }

    @ViewBuilder
    private var continuityStatusContent: some View {
            if let error = viewModel.errorMessage {
                OperatorErrorBanner(message: error, retry: viewModel.load)
            }
            if let error = viewModel.commandErrorMessage {
                Label {
                    Text(error).font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GraphitePalette.warning)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GraphitePalette.panelRaised, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(GraphitePalette.warning.opacity(0.5), lineWidth: 1)
                }
                .accessibilityIdentifier("continuity-delete-error")
            }
            if let notice = viewModel.notice { OperatorNoticeBanner(message: notice) }
    }

    private var continuityControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            continuityHeader
            actions
        }
    }

    private var continuityProjects: some View {
        GraphitePanel(title: "Project IDs") { projectList }
            .accessibilityIdentifier("continuity-project-frame")
    }

    private var continuityPackets: some View {
        GraphitePanel(title: "Continuity packets") { packetList }
            .accessibilityIdentifier("continuity-packet-frame")
    }

    private var packetBrowser: some View {
        HSplitView {
            continuityProjects.frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            continuityPackets.frame(minWidth: 420, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectList: some View {
        List(selection: $viewModel.selectedProjectID) {
            if viewModel.projectIDs.isEmpty, !viewModel.isLoading {
                Text("No continuity projects")
                    .font(.headline)
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
        .scrollContentBackground(.hidden)
        .background(GraphitePalette.panelBottom)
        .accessibilityIdentifier("continuity-project-list")
    }

    private var packetList: some View {
        List(selection: $selectedPacketIDs) {
            if viewModel.packets.isEmpty, !viewModel.isLoadingPackets {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No continuity packets")
                        .font(.headline)
                    Text("Handoffs and checkpoints appear automatically when Forge saves continuity.")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(GraphitePalette.textSecondary)
                }
                .padding(.vertical, 12)
                .accessibilityIdentifier("continuity-packets-empty")
            }
            ForEach(viewModel.packets) { packet in
                VStack(alignment: .leading, spacing: 4) {
                    Text(packet.packetID)
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 8) {
                        Text(packet.type.capitalized)
                        Text(packet.source.rawValue)
                        Text(packet.timestamp)
                    }
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
                }
                .padding(.vertical, 4)
                .tag(packet.packetID)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(packet.type) \(packet.packetID) \(packet.timestamp)")
                .accessibilityIdentifier("continuity-packet-row-\(packet.packetID)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GraphitePalette.panelBottom)
        .overlay {
            if viewModel.isLoadingPackets { ProgressView().controlSize(.small) }
        }
        .accessibilityIdentifier("continuity-packet-list")
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Copy Project ID") {
            guard let projectID = viewModel.selectedProjectID else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(projectID, forType: .string)
        }
        .disabled(viewModel.selectedProjectID == nil)
        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
        .accessibilityIdentifier("continuity-copy-project-id")

        Button("Delete", role: .destructive) { confirmsPacketDeletion = true }
            .buttonStyle(GraphiteButtonStyle(kind: .destructive))
            .disabled(!viewModel.canDeleteSelectedPackets)
            .accessibilityIdentifier("continuity-delete-packets")

        Button("Reset", role: .destructive) { confirmsReset = true }
        .buttonStyle(GraphiteButtonStyle(kind: .destructive))
        .disabled(!viewModel.canResetSelectedProject)
        .accessibilityIdentifier("continuity-reset")

        Button("Clear Cache", role: .destructive) { showClearCacheConfirmation = true }
            .buttonStyle(GraphiteButtonStyle(kind: .destructive))
            .disabled(viewModel.isClearingCache)
            .help("Removes disposable continuity cache without deleting packets or project files.")
            .accessibilityIdentifier("continuity-clear-cache")

        if !viewModel.deletingPacketIDs.isEmpty {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Deleting selected continuity packets")
        }
    }
}
