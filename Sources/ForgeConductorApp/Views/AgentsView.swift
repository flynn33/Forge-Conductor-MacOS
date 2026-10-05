// AgentsView.swift
// What: Displays available agent playbooks and their live session health.
// How: Read-only catalog rows consume AgentCard values; maintenance uses AppModel.

import ForgeConductorCore
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    pageHeader
                    Spacer(minLength: 16)
                    pruneButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    pageHeader
                    pruneButton
                }
            }
            if model.agentCards.isEmpty {
                GraphitePanel {
                    ContentUnavailableView(
                        "No agents in the catalog", systemImage: "person.3.sequence",
                        description: Text("Available agent playbooks appear here with their current session health."))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.agentCards) { agent in
                            agentRow(agent)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(GraphitePalette.canvas)
        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
    }

    private var pageHeader: some View {
        GraphitePageHeader(title: "Agents", subtitle: "\(model.agentCards.count) catalog playbooks")
            .accessibilityIdentifier("detail-agents")
    }

    private var pruneButton: some View {
        Button("Prune idle sessions") { model.pruneSessions() }
    }

    private func agentRow(_ agent: AgentCard) -> some View {
        GraphitePanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.square")
                    .font(.title2)
                    .foregroundStyle(GraphitePalette.info)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(agent.name)
                                .font(.headline)
                                .foregroundStyle(GraphitePalette.textPrimary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            agentHealth(agent)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(agent.name)
                                .font(.headline)
                                .foregroundStyle(GraphitePalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            agentHealth(agent)
                        }
                    }
                    Text(agent.description.isEmpty ? agent.agentID : agent.description)
                        .font(.callout)
                        .lineSpacing(2)
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                    if !agent.tools.isEmpty {
                        Text(agent.tools.joined(separator: " · "))
                            .font(.system(.caption, design: .monospaced))
                            .lineSpacing(2)
                            .foregroundStyle(GraphitePalette.info)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(agent.status)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(GraphitePalette.textMuted)
                }
            }
        }
    }

    private func agentHealth(_ agent: AgentCard) -> some View {
        Label(agent.healthLabel, systemImage: "circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(agent.live ? GraphitePalette.success : GraphitePalette.textSecondary)
    }
}
