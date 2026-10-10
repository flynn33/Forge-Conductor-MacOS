// MCPServersView.swift
// What: Shows MCP connector health and exposes the complete LM Studio deploy action.
// How: Typed server cards and installer status come from AppModel; buttons invoke
// model methods that own transactional configuration, reload, and verification.
// Why: Connection side effects stay behind Core protocols instead of leaking into UI.

import ForgeConductorCore
import SwiftUI

/// Presents MCP server health and the transactional LM Studio deployment workflow.
///
/// The view reports installer and verification states while `AppModel` performs all
/// filesystem, process, reload, and connector work through Core abstractions.
struct MCPServersView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NativeWorkspaceView(viewID: "mcp", descriptors: NativeWorkspaceCatalog.mcp,
                            defaultContent: { defaultContent }, panelContent: workspacePanel)
            .onAppear { model.refreshLMStudioPluginStatus() }
    }

    private func workspacePanel(_ id: String, _ visible: Bool) -> AnyView {
        switch id {
        case "mcp-controls": AnyView(mcpControls)
        case "mcp-plugin-status": AnyView(pluginStatusBanner)
        case "mcp-servers": AnyView(serverCollection)
        case "mcp-guidance": AnyView(productFlowBanner)
        default: AnyView(EmptyView())
        }
    }

    private var defaultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            mcpControls
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pluginStatusBanner
                    serverCollection
                    productFlowBanner
                }
            }
        }
        .padding(20)
        .background(GraphitePalette.canvas)
        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
    }

    @ViewBuilder
    private var mcpControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            GraphitePageHeader(
                title: "LM Studio · MCP",
                subtitle: "\(model.mcpServerCards.filter(\.live).count) live · \(model.mcpServerCards.count) total"
            )
            .accessibilityIdentifier("detail-mcp")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { deploymentActions }
                VStack(alignment: .leading, spacing: 10) { deploymentActions }
            }
        }
    }

    @ViewBuilder
    private var serverCollection: some View {
        if model.mcpServerCards.isEmpty {
            GraphitePanel {
                ContentUnavailableView(
                    "No LM Studio MCP activity yet",
                    systemImage: "server.rack",
                    description: Text(
                        "Click Deploy to LM Studio. Forge writes and validates all required configuration, reloads LM Studio, and verifies both hosted connections automatically."
                    )
                )
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                ForEach(model.mcpServerCards) { server in serverCard(server) }
            }
        }
    }

    @ViewBuilder
    private var deploymentActions: some View {
        Button("Deploy to LM Studio") { model.deployToLMStudio() }
            .buttonStyle(GraphiteButtonStyle(kind: .primary))
            .disabled(model.isInstallingPlugin)
            .help("Transactionally configure primary + failover, reload LM Studio, and verify both hosted connections")
            .accessibilityIdentifier("mcp-deploy-lmstudio")
        Button("Refresh") {
            model.refreshLMStudioPluginStatus()
            model.refresh(force: true)
        }
        Button("Prune presence") { model.prunePresence() }
    }

    private var productFlowBanner: some View {
        GraphitePanel(title: "Deployment workflow") {
            Text(
                "Install LM Studio → Install Forge Conductor → Deploy to LM Studio (this button) → Use tools / agents."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760, alignment: .leading)
            Text(
                "Deploy owns the complete operation: it writes main + failover configuration, triggers hot reload (or relaunches LM Studio), verifies LM Studio synchronized the exact revision, and independently checks both tool servers."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder
    private var pluginStatusBanner: some View {
        let st = model.lmStudioPluginStatus
        GraphitePanel {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(
                    systemName: st?.isFullyInstalled == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(st?.isFullyInstalled == true ? GraphitePalette.success : GraphitePalette.warning)
                Text(
                    st == nil
                        ? "Checking LM Studio deployment"
                        : (st?.isFullyInstalled == true
                            ? "LM Studio connection deployed" : "Not fully deployed to LM Studio")
                )
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.isInstallingPlugin {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(st?.detail ?? "Checking deploy status…")
                .font(.callout)
                .lineSpacing(2)
                .foregroundStyle(GraphitePalette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 760, alignment: .leading)
            if let msg = model.lmStudioPluginMessage, !msg.isEmpty {
                Text(msg)
                    .font(.callout)
                    .lineSpacing(2)
                    .foregroundStyle(GraphitePalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], alignment: .leading, spacing: 8) {
                labeledBit("main (primary)", st?.primaryPluginInstalled)
                labeledBit("failover", st?.fallbackPluginInstalled)
                labeledBit("mcp.json", st?.mcpJSONRegistered)
                labeledBit("serve binary", st?.binaryExecutable)
            }
            .font(.caption)
            if let path = st?.binaryPath {
                Text("Serve binary: \(path)")
                    .font(.system(.caption, design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "No manual file editing or LM Studio restart is required. A deployment may relaunch LM Studio when hot reload cannot replace a stale plugin process; plugin selection remains a per-chat LM Studio choice."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func labeledBit(_ title: String, _ ok: Bool?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(
                    ok == true
                        ? GraphitePalette.success : (ok == false ? GraphitePalette.warning : GraphitePalette.textMuted)
                )
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(GraphitePalette.textSecondary)
            Text(ok.map { $0 ? "yes" : "no" } ?? "pending")
                .foregroundStyle(GraphitePalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func serverCard(_ s: MCPServerCard) -> some View {
        let tone = TelemetryHealth.tone(for: s.health)
        let color = tone.color

        return GraphitePanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(serverDisplayName(s))
                        .font(.headline)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    Text(s.healthLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(serverDisplayName(s))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(s.healthLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(color)
                }
            }
            Text("\(s.hostKind) · \(s.status)")
                .font(.caption)
                .foregroundStyle(GraphitePalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("pid \(s.pid.map(String.init) ?? "—")")
                    .font(.system(.caption, design: .monospaced))
                Spacer(minLength: 8)
                Text(s.source)
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
            }
            if !s.healthReason.isEmpty {
                Text(s.healthReason)
                    .font(.callout)
                    .lineSpacing(2)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(s.live ? "live process" : (s.health == "config" ? "configured · starts on demand" : "not running"))
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(tone.rawValue)
    }

    private func serverDisplayName(_ server: MCPServerCard) -> String {
        guard server.label.lowercased().contains("forge-conductor") else {
            return server.label
        }
        switch server.role {
        case "fallback": return "Forge Conductor · Failover"
        case "primary": return "Forge Conductor · Primary"
        default: return server.label
        }
    }
}
