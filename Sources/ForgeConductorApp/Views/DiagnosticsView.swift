// DiagnosticsView.swift
// What: Browses structured diagnostic events and starts native export workflows.
// How: It renders typed envelopes from AppModel and delegates refresh/export actions
// to the model so filesystem and serialization work never occurs in the view.
// Why: Operators need observable failure evidence without coupling UI to log storage.

import SwiftUI
import ForgeConductorCore

/// Persistent diagnostic log browser + JSON / Markdown export.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Diagnostics")
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("detail-diagnostics")
                Spacer(minLength: 12)
                Text(model.telemetryModeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh log") {
                    model.refreshDiagnosticsPreview()
                }
                Button("Export JSON + Markdown…") {
                    model.exportDiagnostics()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("diagnostics-export")
                Button("Export to ~/…/exports") {
                    model.exportDiagnosticsToDefaultFolder()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if let msg = model.lastExportMessage {
                Text(msg)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .foregroundStyle(.secondary)
            }

            Text("Comprehensive append-only log under ~/.forge-conductor/logs/forge-diagnostics.jsonl. Export writes structured .json and operator .md.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            if let runtime = model.runtimeDiagnosticSnapshot {
                runtimeSummary(runtime)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("diagnostics-runtime-summary")
            }

            if model.diagnosticPreview.isEmpty {
                ContentUnavailableView(
                    "No diagnostic records yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Deploy to LM Studio, use tools, or restart the app to generate log events.")
                )
            } else {
                List {
                    ForEach(Array(model.diagnosticPreview.reversed()), id: \.identityKey) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(row.severity.rawValue.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(severityColor(row.severity))
                                Text(row.category.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(row.tsISO)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(row.event)
                                .font(.subheadline.weight(.semibold))
                            if !row.fields.isEmpty {
                                Text(row.fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear {
            model.refreshDiagnosticsPreview()
        }
    }

    private func runtimeSummary(_ snapshot: RuntimeDiagnosticSnapshot) -> some View {
        let queue = snapshot.gauges[RuntimeGauge.telemetryLogicalQueueDepth.rawValue] ?? 0
        let queueMaximum = snapshot.gauges[RuntimeGauge.telemetryMaximumQueueDepth.rawValue] ?? 0
        let history = snapshot.gauges[RuntimeGauge.telemetryHistorySize.rawValue] ?? 0
        let draws = snapshot.counters[RuntimeCounter.gaugeDraws.rawValue] ?? 0
        let pipelines = snapshot.counters[RuntimeCounter.gaugePipelinesCreated.rawValue] ?? 0
        let buffers = snapshot.counters[RuntimeCounter.gaugeBuffersCreated.rawValue] ?? 0
        return HStack(spacing: 12) {
            metric("Queue", "\(queue) / max \(queueMaximum)")
            metric("History", "\(history)")
            metric("Gauge draws", "\(draws)")
            metric("Pipelines", "\(pipelines)")
            metric("Buffers", "\(buffers)")
            Spacer(minLength: 0)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func severityColor(_ s: DiagnosticSeverity) -> Color {
        switch s {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        case .critical: return .purple
        }
    }
}
