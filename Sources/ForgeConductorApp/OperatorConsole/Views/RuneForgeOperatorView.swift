// RuneForgeOperatorView.swift
// Native policy-source and violation browser backed by the manager-owned API.

import SwiftUI
import ForgeConductorCore

private enum RuneForgeSelection: Hashable {
    case overview
    case source(String)
    case violation(String)
}

struct RuneForgeOperatorView: View {
    @StateObject private var viewModel: RuneForgeViewModel
    @State private var selection: RuneForgeSelection? = .overview
    private let selectPolicySource: @MainActor () -> URL?

    init(
        client: any RuneForgeManagerClientProtocol,
        selectPolicySource: @escaping @MainActor () -> URL? = {
            RuneForgePolicyPicker.select()
        }
    ) {
        _viewModel = StateObject(wrappedValue: RuneForgeViewModel(client: client))
        self.selectPolicySource = selectPolicySource
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = viewModel.noticeMessage {
                OperatorNoticeBanner(message: notice)
            }
            if let error = viewModel.errorMessage {
                OperatorErrorBanner(message: error, retry: viewModel.refresh)
            }
            NavigationSplitView {
                navigationList
                    .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
            } detail: {
                detail
            }
        }
        .padding(20)
        .task { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Rune Forge")
                    .font(.title2.bold())
                    .accessibilityIdentifier("rune-forge-view")
                Text("Development Policy sources and Stjornarvald history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail-rune-forge")
            }
            Spacer()
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Add Development Policy…", systemImage: "plus") {
                guard let url = selectPolicySource() else { return }
                viewModel.addPolicySource(url)
            }
            .accessibilityIdentifier("rune-policy-add")
            Button("Refresh", systemImage: "arrow.clockwise") {
                viewModel.scan()
            }
            .accessibilityIdentifier("rune-policy-refresh")
            Button("Export Policy Log", systemImage: "square.and.arrow.up") {
                viewModel.requestExport()
            }
            .accessibilityIdentifier("rune-policy-export")
        }
    }

    private var navigationList: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "shield.lefthalf.filled")
                .tag(RuneForgeSelection.overview)

            Section {
                if viewModel.sources.isEmpty {
                    Text("No selected policy sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.sources) { source in
                    Button {
                        selection = .source(source.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: source.origin == .builtInRavenForge
                                  ? "shield.checkered"
                                  : "doc.badge.gearshape")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.displayName)
                                    .lineLimit(1)
                                Text(RuneForgeViewModel.sourceStateTitle(source.interpretationState))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(RuneForgeSelection.source(source.id))
                    .accessibilityIdentifier("rune-policy-source-row-\(source.id)")
                }
            } header: {
                Text("Development Policy sources")
                    .accessibilityIdentifier("rune-policy-source-list")
            }

            Section {
                if viewModel.violations.isEmpty {
                    Text("No current policy violations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.violations, id: \.violation.id) { item in
                    Button {
                        selection = .violation(item.violation.id.description)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.violation.latestSummary)
                                .lineLimit(1)
                            Text(RuneForgeViewModel.violationStateTitle(item.violation.state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(RuneForgeSelection.violation(item.violation.id.description))
                    .accessibilityIdentifier(
                        "rune-violation-row-\(item.violation.id.description)"
                    )
                }
            } header: {
                Text("Policy violations")
                    .accessibilityIdentifier("rune-violation-list")
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            overview
        case .source(let id):
            if let source = viewModel.sources.first(where: { $0.id == id }) {
                sourceDetail(source)
            } else {
                overview
            }
        case .violation(let id):
            if let item = viewModel.violations.first(where: {
                $0.violation.id.description == id
            }) {
                violationDetail(item)
            } else {
                overview
            }
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHeading(
                    "Development Policy",
                    subtitle: "Observes and reports policy issues without stopping development"
                )
                GroupBox("Governing policy") {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Authority", viewModel.governingPolicy?.authority ?? "Raven Forge Development")
                        detailRow("Version", viewModel.governingPolicy?.version ?? "Loading")
                        detailRow("Revision", viewModel.governingPolicy?.revision ?? "Loading")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Stjornarvald health") {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("State", healthTitle)
                        detailRow("Active policy sources", "\(viewModel.sources.filter(\.active).count)")
                        detailRow("Current violations", "\(viewModel.violations.count)")
                        detailRow("Development status", "Continuing")
                        if viewModel.isDegraded {
                            Text("Cached policy information remains available while the Manager reconnects.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !viewModel.limitations.isEmpty {
                    GroupBox("Current limitations") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.limitations, id: \.self) { limitation in
                                Label(limitation, systemImage: "info.circle")
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
        }
    }

    private func sourceDetail(_ source: RuneForgeSourceItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHeading(
                    source.displayName,
                    subtitle: source.origin == .builtInRavenForge
                        ? "Built-in Raven Forge Development baseline"
                        : "Active policy source"
                )
                HStack {
                    Button("Refresh Source", systemImage: "arrow.clockwise") {
                        viewModel.refreshSource(source)
                    }
                    .disabled(source.sourceID == nil)
                    Button("Remove Source", systemImage: "minus.circle", role: .destructive) {
                        viewModel.removeSource(source)
                        selection = .overview
                    }
                    .disabled(source.origin == .builtInRavenForge)
                }
                GroupBox("Source identity") {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("State", RuneForgeViewModel.sourceStateTitle(source.interpretationState))
                        detailRow("Source ID", source.sourceID?.description ?? "Manager confirmation pending")
                        detailRow("Kind", source.rootKind.rawValue.replacingOccurrences(of: "_", with: " "))
                        detailRow("Added", source.addedAt.formatted(date: .abbreviated, time: .standard))
                        detailRow("Revision", source.latestRevisionID?.description ?? "Not indexed yet")
                        detailRow("Catalog cursor", source.lastIndexCursor ?? "Not available")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Path and interpretation") {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Selected path", source.selectedPath)
                        detailRow("Standardized path", source.standardizedPath)
                        if let observation = source.latestObservation {
                            detailRow("Interpretation observation", observation)
                        }
                        Text("Every file and folder format is accepted. Unsupported or opaque content remains active with metadata-only or partial interpretation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }

    private func violationDetail(_ item: StjornarvaldViolationPageItem) -> some View {
        let violation = item.violation
        let event = viewModel.latestEvent(for: violation.id)
        let history = viewModel.eventHistory(for: violation.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHeading(
                    RuneForgeViewModel.violationStateTitle(violation.state),
                    subtitle: violation.latestSummary
                )
                GroupBox("Violation identity and history") {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Violation ID", violation.id.description)
                        detailRow("State", RuneForgeViewModel.violationStateTitle(violation.state))
                        detailRow("Rule", violation.ruleID.description)
                        detailRow("Policy revision", violation.policyRevision)
                        detailRow("Occurrences", "\(violation.occurrenceCount)")
                        detailRow("First observed", violation.firstObservedAt.formatted(date: .abbreviated, time: .standard))
                        detailRow("Last observed", violation.lastObservedAt.formatted(date: .abbreviated, time: .standard))
                        detailRow("Latest event sequence", "\(item.latestEventSequence)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Evidence and interpretation") {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Summary", violation.latestSummary)
                        detailRow("Suggested correction", violation.latestSuggestedCorrection)
                        if let event {
                            detailRow("Policy source", event.candidate.rule.source.path)
                            detailRow("Source locator", event.candidate.rule.source.locator)
                            detailRow("Explanation", event.candidate.explanation)
                            detailRow("Confidence", event.candidate.confidence.formatted(.percent.precision(.fractionLength(0))))
                            detailRow("Delivery", event.noticeState.replacingOccurrences(of: "_", with: " "))
                            if !event.candidate.evidenceReferences.isEmpty {
                                detailRow("Observed evidence", event.candidate.evidenceReferences.joined(separator: "\n"))
                            }
                            if !event.candidate.assumptions.isEmpty {
                                detailRow("Assumptions", event.candidate.assumptions.joined(separator: "\n"))
                            }
                            if !event.candidate.alternatives.isEmpty {
                                detailRow("Alternatives", event.candidate.alternatives.joined(separator: "\n"))
                            }
                        }
                        detailRow("Development status", "Continuing; no tool, run, or queue was restricted")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Occurrence history") {
                    VStack(alignment: .leading, spacing: 10) {
                        if history.isEmpty {
                            Text("No occurrence events are present in the bounded manager snapshot.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(history) { historyEvent in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(eventTitle(historyEvent.type))
                                    .font(.callout.weight(.semibold))
                                Text(historyEvent.occurredAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(historyEvent.candidate.summary)
                                    .font(.caption)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }

    private var healthTitle: String {
        guard let health = viewModel.health else {
            return viewModel.isDegraded ? "Manager unavailable — cached data" : "Loading"
        }
        switch health.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Observing"
        case .degraded: return "Degraded — development continuing"
        case .stopping: return "Stopping"
        }
    }

    private func detailHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func eventTitle(_ type: PolicyViolationEventType) -> String {
        switch type {
        case .opened: return "Policy violation"
        case .repeated: return "Repeated"
        case .evidenceUpdated: return "Evidence updated"
        case .corrected: return "Corrected"
        case .reopened: return "Reopened"
        case .disputed: return "Interpretation observation"
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
