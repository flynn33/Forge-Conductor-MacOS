// LiveFeedView.swift
// What: Presents recent tool activity as a compact native event stream.
// How: It formats immutable LiveFeedEvent values supplied by AppModel in a SwiftUI List.
// Why: A read-only projection keeps audit collection independent of presentation.

import ForgeConductorCore
import SwiftUI

/// Displays recent audited tool executions without initiating collection or storage.
///
/// The view consumes presentation-ready events from `AppModel`, keeping timestamps,
/// status coloring, and truncation policy local to this module.
struct LiveFeedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let outcomes = AuditOutcomeCounts.summarize(statuses: model.liveFeedEvents.map(\.status))
        VStack(alignment: .leading, spacing: 16) {
            GraphitePageHeader(title: "Live Feed", subtitle: "Recent audited tool activity")
                .accessibilityIdentifier("detail-feed")
            HStack(spacing: 16) {
                Text("\(model.liveFeedEvents.count) events")
                    .foregroundStyle(GraphitePalette.textSecondary)
                Text("ERR \(outcomes.errorCount)").foregroundStyle(GraphitePalette.failure)
                Text("DEN \(outcomes.deniedCount)").foregroundStyle(GraphitePalette.warning)
                Text("WARN \(outcomes.warnCount)").foregroundStyle(GraphitePalette.warning)
            }
            .font(.caption.weight(.medium))
            if model.liveFeedEvents.isEmpty {
                GraphitePanel {
                    ContentUnavailableView(
                        "No recent tool activity", systemImage: "waveform.path",
                        description: Text("Audited tool results appear here as they arrive."))
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Time").frame(width: 72, alignment: .leading)
                        Text("Result").frame(width: 92, alignment: .leading)
                        Text("Tool").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Duration").frame(width: 74, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(GraphitePalette.panelRaised)
                    Rectangle().fill(GraphitePalette.separator).frame(height: 1)
                    List {
                        ForEach(Array(model.liveFeedEvents.enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(String(event.timestamp.suffix(8)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                    .frame(width: 72, alignment: .leading)
                                    .help(event.timestamp)
                                Text(event.status.uppercased())
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(statusColor(event.status))
                                    .frame(width: 92, alignment: .leading)
                                Text(event.tool)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(GraphitePalette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(event.tool)
                                Text(event.durationMs.map { "\($0) ms" } ?? "—")
                                    .font(.system(.caption, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                    .frame(width: 74, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(GraphitePalette.panelBottom)
                            .listRowSeparatorTint(GraphitePalette.separator)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                .background(GraphitePalette.panelBottom)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(GraphitePalette.panelBorder, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(GraphitePalette.canvas)
    }

    private func statusColor(_ status: String) -> Color {
        switch AuditOutcome(status: status) {
        case .success:
            return GraphitePalette.success
        case .operationalError:
            return GraphitePalette.failure
        case .policyDenied:
            return GraphitePalette.warning
        case .maintenanceWarning:
            return GraphitePalette.warning
        case .other:
            return GraphitePalette.textSecondary
        }
    }
}
