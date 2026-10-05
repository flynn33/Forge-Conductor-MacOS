// DiagnosticsView.swift
// What: Browses structured diagnostic events and starts native export workflows.
// How: It renders typed envelopes from AppModel and delegates refresh/export actions
// to the model so filesystem and serialization work never occurs in the view.
// Why: Operators need observable failure evidence without coupling UI to log storage.

import ForgeConductorCore
import SwiftUI

/// Persistent diagnostic log browser + JSON / Markdown export.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GraphitePageHeader(title: "Diagnostics", subtitle: model.telemetryModeLabel)
                .accessibilityIdentifier("detail-diagnostics")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { exportActions }
                VStack(alignment: .leading, spacing: 10) { exportActions }
            }
            GraphitePanel {
                Text(
                    "Comprehensive append-only log under ~/.forge-conductor/logs/forge-diagnostics.jsonl. Export writes structured .json and operator .md."
                )
                .font(.callout)
                .lineSpacing(2)
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 760, alignment: .leading)
                if model.isExportingDiagnostics {
                    ProgressView("Exporting diagnostics…")
                        .controlSize(.small)
                }
                if let message = model.lastExportMessage {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.app == nil {
                    Text(
                        "Startup diagnostics remain available before the app starts. If log storage is unavailable, choose another export folder; the export identifies any omitted history."
                    )
                    .font(.callout)
                    .lineSpacing(2)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
                    .accessibilityIdentifier("diagnostics-startup-status")
                }
                if let runtime = model.runtimeDiagnosticSnapshot {
                    runtimeSummary(runtime)
                        .accessibilityIdentifier("diagnostics-runtime-summary")
                }
            }
            if model.diagnosticPreview.isEmpty {
                GraphitePanel {
                    ContentUnavailableView(
                        "No diagnostic records yet", systemImage: "doc.text.magnifyingglass",
                        description: Text("Deploy to LM Studio, use tools, or restart the app to generate log events."))
                }
            } else {
                List {
                    ForEach(Array(model.diagnosticPreview.reversed()), id: \.identityKey) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.severity.rawValue.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(severityColor(row.severity))
                                Text(row.category.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                Spacer(minLength: 8)
                                Text(row.tsISO)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(GraphitePalette.textMuted)
                            }
                            Text(row.event)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(GraphitePalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !row.fields.isEmpty {
                                Text(row.fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
                                    .font(.system(.caption, design: .monospaced))
                                    .lineSpacing(2)
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(GraphitePalette.panelBottom)
                        .listRowSeparatorTint(GraphitePalette.separator)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(GraphitePalette.panelBottom)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(GraphitePalette.panelBorder, lineWidth: 1))
            }
        }
        .padding(20)
        .background(GraphitePalette.canvas)
        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
        .onAppear { model.refreshDiagnosticsPreview() }
    }

    @ViewBuilder
    private var exportActions: some View {
        Button("Refresh log") { model.refreshDiagnosticsPreview() }
        Button("Export JSON + Markdown…") { model.exportDiagnostics() }
            .buttonStyle(GraphiteButtonStyle(kind: .primary))
            .accessibilityIdentifier("diagnostics-export")
            .disabled(model.isExportingDiagnostics)
        Button("Export to ~/…/exports") { model.exportDiagnosticsToDefaultFolder() }
            .accessibilityIdentifier("diagnostics-export-default")
            .disabled(model.isExportingDiagnostics)
    }

    private func runtimeSummary(_ snapshot: RuntimeDiagnosticSnapshot) -> some View {
        let queue = snapshot.gauges[RuntimeGauge.telemetryLogicalQueueDepth.rawValue] ?? 0
        let queueMaximum = snapshot.gauges[RuntimeGauge.telemetryMaximumQueueDepth.rawValue] ?? 0
        let history = snapshot.gauges[RuntimeGauge.telemetryHistorySize.rawValue] ?? 0
        let draws = snapshot.counters[RuntimeCounter.gaugeDraws.rawValue] ?? 0
        let pipelines = snapshot.counters[RuntimeCounter.gaugePipelinesCreated.rawValue] ?? 0
        let buffers = snapshot.counters[RuntimeCounter.gaugeBuffersCreated.rawValue] ?? 0
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 10)], alignment: .leading, spacing: 10) {
            metric("Queue", "\(queue) / max \(queueMaximum)")
            metric("History", "\(history)")
            metric("Gauge draws", "\(draws)")
            metric("Pipelines", "\(pipelines)")
            metric("Buffers", "\(buffers)")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(GraphitePalette.textSecondary)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GraphitePalette.panelRaised, in: RoundedRectangle(cornerRadius: 6))
    }

    private func severityColor(_ s: DiagnosticSeverity) -> Color {
        switch s {
        case .info: return GraphitePalette.textSecondary
        case .warn: return GraphitePalette.warning
        case .error: return GraphitePalette.failure
        case .critical: return GraphitePalette.failure
        }
    }
}
