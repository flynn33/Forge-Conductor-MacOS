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
        VStack(alignment: .leading, spacing: 14) {
            OperatorHeader(
                title: "Events & Evidence",
                subtitle: "Up to 100 redacted manager events per page with durable resource references",
                isLoading: viewModel.isLoading,
                onRefresh: viewModel.load
            )
            if let error = viewModel.errorMessage {
                OperatorErrorBanner(message: error, retry: viewModel.load)
            }
            HStack {
                TextField("Filter by event or resource identifier", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("evidence-search")
                Button("Export Diagnostics") { appModel.exportDiagnostics() }
                    .accessibilityIdentifier("evidence-export")
            }

            List(viewModel.filteredEvents) { event in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(event.kind.replacingOccurrences(of: "_", with: " "))
                            .font(.headline)
                        Spacer()
                        Text(event.timestamp)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(event.summary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    referenceRow(event)
                }
                .padding(.vertical, 5)
                .accessibilityIdentifier("evidence-event-\(event.eventID)")
            }
            .overlay {
                if viewModel.filteredEvents.isEmpty, viewModel.errorMessage == nil, !viewModel.isLoading {
                    ContentUnavailableView(
                        viewModel.events.isEmpty ? "No Events" : "No Matching Events",
                        systemImage: "list.bullet.rectangle",
                        description: Text("The bounded manager page contains no events for this view.")
                    )
                }
            }

            HStack {
                Text("Showing \(viewModel.filteredEvents.count) of \(viewModel.events.count) bounded events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.nextCursor != nil {
                    Button("Load Older Events", action: viewModel.loadMore)
                        .controlSize(.small)
                        .disabled(viewModel.isLoadingMore)
                        .accessibilityIdentifier("evidence-load-more")
                    if viewModel.isLoadingMore { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(20)
        .task { viewModel.load() }
        .accessibilityIdentifier("evidence-operator-view")
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
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
