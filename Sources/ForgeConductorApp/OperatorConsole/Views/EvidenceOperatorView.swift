// EvidenceOperatorView.swift
// Bounded, searchable manager event list with redacted cross-resource references.

import SwiftUI

struct EvidenceOperatorView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: EvidenceViewModel

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: EvidenceViewModel(client: client))
    }

    var body: some View {
        NativeWorkspaceView(viewID: "evidence", descriptors: NativeWorkspaceCatalog.evidence,
                            defaultContent: { defaultContent }, panelContent: workspacePanel)
            .task { viewModel.load() }
    }

    private func workspacePanel(_ id: String, _ visible: Bool) -> AnyView {
        switch id {
        case "evidence-controls": AnyView(evidenceControls)
        case "evidence-events": AnyView(eventRecords)
        case "evidence-paging": AnyView(eventPaging)
        default: AnyView(EmptyView())
        }
    }

    private var defaultContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            evidenceControls
            eventRecords
            eventPaging
        }
        .padding(20)
        .background(GraphitePalette.canvas)
    }

    @ViewBuilder
    private var evidenceControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            OperatorHeader(
                title: "Events & Evidence",
                subtitle: "Up to 100 redacted manager events per page with durable resource references",
                isLoading: viewModel.isLoading,
                titleAccessibilityIdentifier: "detail-evidence",
                subtitleAccessibilityIdentifier: "evidence-operator-view",
                onRefresh: viewModel.load
            )
            if let error = viewModel.errorMessage {
                OperatorErrorBanner(message: error, retry: viewModel.load)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    searchField
                    exportButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    searchField
                    exportButton
                }
            }
        }
    }

    @ViewBuilder
    private var eventRecords: some View {
        GraphitePanel {
            List(viewModel.filteredEvents) { event in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.kind.replacingOccurrences(of: "_", with: " "))
                            .font(.headline)
                        Spacer()
                        Text(event.timestamp)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(GraphitePalette.textSecondary)
                    }
                    Text(event.summary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    referenceRow(event)
                }
                .padding(.vertical, 8)
                .listRowSeparatorTint(GraphitePalette.separator)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("evidence-event-\(event.eventID)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(GraphitePalette.panelBottom)
            .overlay {
                if viewModel.filteredEvents.isEmpty, viewModel.errorMessage == nil, !viewModel.isLoading {
                    ContentUnavailableView(
                        viewModel.events.isEmpty ? "No Events" : "No Matching Events",
                        systemImage: "list.bullet.rectangle",
                        description: Text("The bounded manager page contains no events for this view.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var eventPaging: some View {

        HStack {
            Text("Showing \(viewModel.filteredEvents.count) of \(viewModel.events.count) bounded events")
                .font(.caption)
                .foregroundStyle(GraphitePalette.textSecondary)
            Spacer()
            if viewModel.nextCursor != nil {
                Button("Load Older Events", action: viewModel.loadMore)
                    .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                    .controlSize(.small)
                    .disabled(viewModel.isLoadingMore)
                    .accessibilityIdentifier("evidence-load-more")
                if viewModel.isLoadingMore { ProgressView().controlSize(.small) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(GraphitePalette.textMuted)
            TextField("Filter by event or resource identifier", text: $viewModel.query)
                .textFieldStyle(GraphiteFieldStyle())
                .accessibilityIdentifier("evidence-search")
        }
        .frame(minWidth: 220)
    }

    private var exportButton: some View {
        Button("Export Diagnostics") { appModel.exportDiagnostics() }
            .buttonStyle(GraphiteButtonStyle(kind: .secondary))
            .accessibilityIdentifier("evidence-export")
    }

    @ViewBuilder
    private func referenceRow(_ event: OperatorEvent) -> some View {
        let references = [
            event.projectID.map { "project \($0)" },
            event.runID.map { "run \($0)" },
            event.operationID.map { "operation \($0)" },
            event.jobID.map { "job \($0)" },
            event.providerRequestID.map { "request \($0)" },
            event.artifactID.map { "artifact \($0)" },
        ].compactMap { $0 }
        if !references.isEmpty {
            Text(references.joined(separator: " · "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
