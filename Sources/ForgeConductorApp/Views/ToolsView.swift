// ToolsView.swift
// What: Lists registered tool modules, activity state, and health.
// How: It filters ToolCard projections locally and renders lazy native rows.
// Why: Discovery stays UI-only while authorization and execution remain in Core.

import ForgeConductorCore
import SwiftUI

/// Lists the registered tool surface and supports local name/category filtering.
///
/// Search state belongs to this view because it is transient presentation state;
/// authoritative tool metadata continues to come from `AppModel`.
struct ToolsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""
    private let tableHorizontalInset: CGFloat = 14

    private var filtered: [ToolCard] {
        let all = model.toolCards
        guard !filter.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.pack.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        NativeWorkspaceView(viewID: "tools", descriptors: NativeWorkspaceCatalog.tools,
                            defaultContent: { defaultContent }, panelContent: workspacePanel)
    }

    private func workspacePanel(_ id: String, _ visible: Bool) -> AnyView {
        switch id {
        case "tools-controls": AnyView(toolsControls)
        case "tools-outcome-legend": AnyView(outcomeLegend)
        case "tools-catalog": AnyView(toolCatalog)
        default: AnyView(EmptyView())
        }
    }

    private var defaultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolsControls
            outcomeLegend
            toolCatalog
        }
        .padding(20)
        .background(GraphitePalette.canvas)
    }

    @ViewBuilder
    private var toolsControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                pageHeader
                Spacer(minLength: 16)
                filterField
            }
            VStack(alignment: .leading, spacing: 12) {
                pageHeader
                filterField
            }
    }
    }

    @ViewBuilder
    private var outcomeLegend: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(GraphitePalette.info)
            VStack(alignment: .leading, spacing: 6) {
                Text("READY means the tool is registered. IDLE is normal until a model invokes it.")
                Text("ERR is an execution failure, DEN is an authorization-policy outcome, and WARN is a maintenance advisory. DEN and WARN do not raise the operational error rate.")
            }
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760, alignment: .leading)
    }
    }

    @ViewBuilder
    private var toolCatalog: some View {
        if filtered.isEmpty {
            GraphitePanel {
                ContentUnavailableView(
                    model.toolCards.isEmpty ? "No tools in the catalog" : "No matching tools",
                    systemImage: "wrench.and.screwdriver",
                    description: Text(
                        model.toolCards.isEmpty
                            ? "Registered tools and their operational health appear here."
                            : "Adjust the tool name or pack filter.")
                )
            }
        } else {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        Text("Tool / pack").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("tools-column-name")
                        Text("Outcomes").frame(minWidth: 132, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("tools-column-outcomes")
                        Text("State").frame(width: 62, alignment: .leading)
                            .accessibilityIdentifier("tools-column-state")
                        Text("Health").frame(width: 86, alignment: .leading)
                            .accessibilityIdentifier("tools-column-health")
                        Text("Activity").frame(width: 120, alignment: .trailing)
                            .accessibilityIdentifier("tools-column-activity")
                    }
                    Text("Tool / pack · state · health · recent activity")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(GraphitePalette.textSecondary)
                .padding(.horizontal, tableHorizontalInset)
                .padding(.vertical, 11)
                .background(GraphitePalette.panelRaised)
                Rectangle().fill(GraphitePalette.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { tool in
                            toolRow(tool)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, tableHorizontalInset)
                                .padding(.vertical, 5)
                                .accessibilityElement(children: .contain)
                                .help(toolHelp(tool))
                            Rectangle().fill(GraphitePalette.separator).frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .contentMargins(.horizontal, 0, for: .scrollContent)
            }
            .background(GraphitePalette.panelBottom)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(GraphitePalette.panelBorder, lineWidth: 1))
    }
    }

    private var pageHeader: some View {
        GraphitePageHeader(title: "Tools", subtitle: "\(filtered.count) of \(model.toolCards.count) registered tools")
            .accessibilityIdentifier("detail-tools")
    }

    private var filterField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Filter by tool or pack")
                .font(.caption.weight(.medium))
                .foregroundStyle(GraphitePalette.textSecondary)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .accessibilityHidden(true)
                TextField("Filter tools", text: $filter)
                    .textFieldStyle(GraphiteFieldStyle())
                    .accessibilityIdentifier("tool-filter")
            }
        }
        .frame(width: 260)
    }

    private func toolRow(_ tool: ToolCard) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                toolName(tool).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) { outcomeBadges(tool.outcomes1h) }
                    .frame(minWidth: 132, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
                toolState(tool).frame(width: 62, alignment: .leading)
                toolHealth(tool).frame(width: 86, alignment: .leading)
                toolActivity(tool).frame(width: 120, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 8) {
                toolName(tool)
                HStack(spacing: 12) {
                    toolState(tool)
                    toolHealth(tool)
                    Spacer(minLength: 4)
                    toolActivity(tool)
                }
                HStack(spacing: 4) { outcomeBadges(tool.outcomes1h) }
            }
        }
    }

    private func toolName(_ tool: ToolCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tool.name)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(GraphitePalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tools-row-name-\(tool.id)")
            Text(tool.pack)
                .font(.caption)
                .foregroundStyle(GraphitePalette.textSecondary)
        }
    }

    private func toolState(_ tool: ToolCard) -> some View {
        Text(tool.status)
            .font(.callout.weight(.semibold))
            .foregroundStyle(statusColor(tool.status))
            .accessibilityIdentifier("tools-row-state-\(tool.id)")
    }

    private func toolHealth(_ tool: ToolCard) -> some View {
        Text(tool.healthLabel)
            .font(.callout)
            .foregroundStyle(TelemetryHealth.tone(for: tool.health).color)
            .accessibilityIdentifier("tools-row-health-\(tool.id)")
    }

    private func toolActivity(_ tool: ToolCard) -> some View {
        Text("\(tool.events5m)/5m · \(tool.events1h)/1h")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(GraphitePalette.textSecondary)
            .accessibilityIdentifier("tools-row-activity-\(tool.id)")
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "active": return GraphitePalette.success
        case "warm": return GraphitePalette.warning
        default: return GraphitePalette.textSecondary
        }
    }

    private func toolHelp(_ tool: ToolCard) -> String {
        let healthDetail: String
        switch TelemetryHealth.tone(for: tool.health) {
        case .healthy:
            healthDetail = "Operational error rate is below the alert threshold."
        case .caution:
            healthDetail = "Recent operational errors exceed the warning threshold."
        case .failure:
            healthDetail = "Recent operational errors exceed the failure threshold."
        case .informational:
            healthDetail = "Configured and available on demand."
        case .unavailable:
            healthDetail = "Health evidence is unavailable."
        }
        let outcomes = tool.outcomes1h
        return
            "\(tool.name) · \(tool.pack) · \(tool.events5m) calls/5m · \(tool.events1h) calls/1h · \(outcomes.errorCount) operational errors · \(outcomes.deniedCount) policy denials · \(outcomes.warnCount) maintenance warnings. \(healthDetail)"
    }

    @ViewBuilder
    private func outcomeBadges(_ outcomes: AuditOutcomeCounts) -> some View {
        if outcomes.errorCount > 0 {
            outcomeBadge("ERR \(outcomes.errorCount)", color: GraphitePalette.failure)
        }
        if outcomes.deniedCount > 0 {
            outcomeBadge("DEN \(outcomes.deniedCount)", color: GraphitePalette.warning)
        }
        if outcomes.warnCount > 0 {
            outcomeBadge("WARN \(outcomes.warnCount)", color: GraphitePalette.warning)
        }
    }

    private func outcomeBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
