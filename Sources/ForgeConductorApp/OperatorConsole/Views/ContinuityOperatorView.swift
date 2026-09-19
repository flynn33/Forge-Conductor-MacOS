// ContinuityOperatorView.swift
// Native rollover operation, context budget, acknowledgment, and recovery detail.

import Foundation
import SwiftUI
import ForgeConductorCore

struct ContinuityOperatorView: View {
    @StateObject private var viewModel: ContinuityViewModel
    @State private var showingAdvancedControls = false
    @State private var showingTechnicalDetails = false

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ContinuityViewModel(client: client))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedOperationID) {
                ForEach(viewModel.operations) { operation in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activityTitle(operation))
                                .lineLimit(1)
                            Text(mission(for: operation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(operation.operationID)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OperatorHeader(
                        title: "Continuity",
                        subtitle: "Automatic progress protection and fresh-session continuation",
                        isLoading: viewModel.isLoading,
                        onRefresh: viewModel.load
                    )
                    continuityStatus
                    if let error = viewModel.errorMessage {
                        OperatorErrorBanner(message: error, retry: viewModel.load)
                    }
                    if let error = viewModel.commandErrorMessage {
                        Label {
                            Text(error)
                                .font(.caption)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("continuity-command-error")
                    }
                    if let notice = viewModel.notice {
                        OperatorNoticeBanner(message: notice)
                    }
                    advancedControls
                    if let operation = viewModel.selectedOperation {
                        operationDetail(operation)
                    } else if viewModel.errorMessage == nil, !viewModel.isLoading {
                        Text("No rollover is active. Automatic continuity is ready and requires no setup.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .accessibilityIdentifier("continuity-no-operation-ready")
                    }
                }
                .padding(20)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: viewModel.selectedOperationID) { _, operationID in
            viewModel.selectRun(forOperationID: operationID)
        }
        .task { viewModel.load() }
        .guidedHelpState(viewModel.guidedHelpState, for: .continuity)
        .accessibilityIdentifier("continuity-operator-view")
    }

    private var continuityStatus: some View {
        GroupBox("Automatic continuity") {
            if let readiness = viewModel.selectedReadiness {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Protection") {
                        OperatorStateBadge(state: stateTitle(readiness.state))
                            .accessibilityIdentifier("continuity-readiness-state")
                    }
                    LabeledContent(
                        "Task",
                        value: selectedTaskTitle(for: readiness)
                    )
                    LabeledContent(
                        "Progress saved",
                        value: progressSaved(readiness.latestCheckpointAt)
                    )
                    LabeledContent(
                        "Working context",
                        value: contextRemaining(readiness)
                    )
                    Text(readiness.detail)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("continuity-readiness-detail")
                    if let next = readiness.nextAutomaticAction {
                        Label(next, systemImage: "arrow.forward.circle")
                            .font(.callout)
                            .accessibilityIdentifier("continuity-next-action")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    OperatorStateBadge(state: "Ready")
                        .accessibilityIdentifier("continuity-readiness-state")
                    Text("Automatic continuity is ready. It starts with the next managed task; no setup is required.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("continuity-readiness-detail")
                }
            }
        }
    }

    private var advancedControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    showingAdvancedControls.toggle()
                } label: {
                    Label(
                        "Advanced controls",
                        systemImage: showingAdvancedControls ? "chevron.down" : "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("continuity-advanced-toggle")
                if showingAdvancedControls {
                    if viewModel.runs.isEmpty {
                        Text("No managed run is available for a manual continuity request.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Managed run", selection: $viewModel.selectedRunID) {
                            Text("Select a managed run").tag(String?.none)
                            ForEach(viewModel.runs) { run in
                                Text("\(run.mission) · \(run.state)")
                                    .tag(String?.some(run.runID))
                            }
                        }
                        .accessibilityIdentifier("continuity-run-selection")

                        if let run = viewModel.selectedRun {
                            LabeledContent("Task state") {
                                OperatorStateBadge(state: run.state)
                                    .accessibilityIdentifier("continuity-selected-run-state")
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Save progress now", action: viewModel.requestCheckpoint)
                            .disabled(!viewModel.canRequestCheckpoint)
                            .accessibilityIdentifier("checkpoint-command")
                        GuidedHelpButton(context: .continuitySaveProgress)
                        Button("Start a fresh session and continue", action: viewModel.requestRollover)
                            .disabled(!viewModel.canRequestRollover)
                            .accessibilityIdentifier("rollover-command")
                        GuidedHelpButton(context: .continuityFreshSession)
                        if let action = viewModel.controlInFlight {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Persisting \(action.rawValue) command")
                        }
                        Spacer()
                    }
                    Text(viewModel.eligibilityMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("continuity-control-eligibility")
                    Text("These optional controls send typed requests only. Eligibility, quiescing, exact observation binding, and durable transitions remain manager-owned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("continuity-controls-authority")
                }
            }
        } label: {
            Text("Optional manual actions")
        }
    }

    private func operationDetail(_ operation: OperatorContinuity) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Current continuity activity") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Status") {
                        OperatorStateBadge(state: activityTitle(operation))
                            .accessibilityIdentifier("rollover-operation-state")
                    }
                    Text(activityDescription(operation))
                        .foregroundStyle(.secondary)
                    if let error = operation.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }

            Button {
                showingTechnicalDetails.toggle()
            } label: {
                Label(
                    "Technical details",
                    systemImage: showingTechnicalDetails ? "chevron.down" : "chevron.right"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("continuity-technical-toggle")

            if showingTechnicalDetails {
                GroupBox("Operation identity") {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent("Mode", value: modeLabel(operation.mode))
                        LabeledContent("Manager control state", value: operation.controlState ?? "Unavailable")
                        LabeledContent("Operation ID") { OperatorIdentifier(operation.operationID) }
                        LabeledContent("Run ID") { OperatorIdentifier(operation.runID) }
                        LabeledContent("Project") { OperatorIdentifier(operation.projectID) }
                        LabeledContent("Generation", value: "\(operation.projectGeneration)")
                        LabeledContent("Attempt", value: "\(operation.attempt)")
                        LabeledContent("Next retry", value: operation.retryAt ?? "No retry scheduled")
                        if let error = operation.lastError {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }

                GroupBox("Context budget") {
                    if let budget = operation.budget {
                        VStack(alignment: .leading, spacing: 10) {
                            budgetGauge(budget)
                            LabeledContent("Capacity", value: tokens(budget.capacityTokens))
                            LabeledContent("Used", value: tokens(budget.usedTokens))
                            LabeledContent("Response reserve", value: tokens(budget.responseReserveTokens))
                            LabeledContent("Handoff reserve", value: tokens(budget.handoffReserveTokens))
                            LabeledContent("Recovery reserve", value: tokens(budget.recoveryReserveTokens))
                            LabeledContent("Remaining", value: tokens(budget.remainingTokens))
                            LabeledContent("Source", value: budget.source ?? "Unavailable")
                            LabeledContent("Confidence", value: budget.confidence ?? "Unavailable")
                            HStack {
                                Text("Checkpoint threshold: \(tokens(budget.checkpointThreshold))")
                                Spacer()
                                Text("Rollover threshold: \(tokens(budget.rolloverThreshold))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("context-threshold-labels")
                        }
                    } else {
                        Text("No persisted context-budget observation was published.")
                        .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Handoff and successor") {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent("Latest checkpoint") { OperatorIdentifier(operation.checkpointID) }
                        LabeledContent("Handoff ID") { OperatorIdentifier(operation.handoffID) }
                        LabeledContent("Handoff checksum") { OperatorIdentifier(operation.handoffSHA256) }
                        LabeledContent("Predecessor") {
                            OperatorIdentifier(operation.predecessorSessionID)
                                .accessibilityIdentifier("continuity-predecessor-id")
                        }
                        LabeledContent("Accepted successor") {
                            OperatorIdentifier(operation.successorSessionID)
                                .accessibilityIdentifier("continuity-successor-id")
                        }
                        LabeledContent("Successor provider response") {
                            OperatorIdentifier(operation.successorProviderResponseID)
                        }
                        LabeledContent("Acknowledgment checksum") {
                            OperatorIdentifier(operation.acknowledgementSHA256)
                        }
                        LabeledContent("Automatic continuation issued", value: operation.continuationIssued ? "Yes" : "No")
                    }
                }
            }

            GroupBox("Ordered event timeline") {
                if viewModel.selectedEvents.isEmpty {
                    Text("No bounded events were linked to this operation.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.selectedEvents) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.summary)
                                    Text(event.timestamp)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

        }
    }

    private func budgetGauge(_ budget: OperatorContextBudget) -> some View {
        let capacity = max(budget.capacityTokens ?? 0, 1)
        let used = min(max(budget.usedTokens ?? 0, 0), capacity)
        return ProgressView(value: Double(used), total: Double(capacity)) {
            Text(budget.action?.replacingOccurrences(of: "_", with: " ") ?? "Budget")
        } currentValueLabel: {
            Text("\(used) of \(capacity) tokens")
        }
        .accessibilityIdentifier("context-gauge")
        .accessibilityValue("\(used) used of \(capacity); \(budget.remainingTokens ?? 0) remaining")
    }

    private func contextRemaining(_ readiness: ManagerContinuityReadiness) -> String {
        guard let capacity = readiness.capacityTokens,
              let remaining = readiness.remainingTokens,
              capacity > 0 else { return "Waiting for the first usage observation" }
        let boundedRemaining = min(max(remaining, 0), capacity)
        let percent = Int((Double(boundedRemaining) / Double(capacity) * 100).rounded())
        return "\(percent)% available"
    }

    private func selectedTaskTitle(for readiness: ManagerContinuityReadiness) -> String {
        guard let runID = readiness.runID?.description,
              let run = viewModel.runs.first(where: { $0.runID == runID }) else {
            return "Next managed task"
        }
        return run.mission
    }

    private func mission(for operation: OperatorContinuity) -> String {
        viewModel.runs.first(where: { $0.runID == operation.runID })?.mission ?? "Managed task"
    }

    private func progressSaved(_ timestamp: String?) -> String {
        guard let timestamp else { return "Not needed yet" }
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func stateTitle(_ state: ManagedContinuityDisplayState) -> String {
        switch state {
        case .ready: "Ready"
        case .monitoring: "Monitoring"
        case .savingProgress: "Saving progress"
        case .rolloverQueued: "Fresh session queued"
        case .quiescing: "Finishing current work"
        case .creatingSuccessor: "Creating fresh session"
        case .restoring: "Restoring task"
        case .continuing: "Continuing"
        case .waitingForProvider: "Waiting for model"
        case .blocked: "Needs attention"
        case .externalCompatibilityOnly: "External host limited"
        case .unavailable: "Unavailable"
        }
    }

    private func displayedState(_ operation: OperatorContinuity) -> String {
        let claimsCompletion = operation.state == "completed" || operation.state == "sealed"
        let durableCompletion = operation.successorSessionID != nil
            && operation.acknowledgementSHA256 != nil
            && operation.continuationIssued
        if claimsCompletion && !durableCompletion {
            return "awaiting_durable_acknowledgement"
        }
        return operation.state
    }

    private func activityTitle(_ operation: OperatorContinuity) -> String {
        switch displayedState(operation) {
        case "queued": "Preparing continuity"
        case "claimed", "running": "Protecting task progress"
        case "retry_wait": "Waiting to retry"
        case "predecessor_sealed", "completed", "sealed": "Task continued"
        case "awaiting_durable_acknowledgement": "Confirming fresh session"
        case "failed": "Needs attention"
        default: "Continuity activity"
        }
    }

    private func activityDescription(_ operation: OperatorContinuity) -> String {
        switch displayedState(operation) {
        case "queued":
            "Forge has durably queued this continuity action."
        case "claimed", "running":
            "Forge is saving or restoring task state through the manager."
        case "retry_wait":
            "Forge retained task state and will retry after the bounded delay."
        case "predecessor_sealed", "completed", "sealed":
            "A fresh accepted session has continued the task and the predecessor is sealed."
        case "awaiting_durable_acknowledgement":
            "Forge is waiting for exact successor acknowledgment before sealing the predecessor."
        case "failed":
            "The durable operation needs attention before automatic continuation can advance."
        default:
            "Forge is protecting the current task through a durable continuity operation."
        }
    }

    private func modeLabel(_ raw: String) -> String {
        switch raw {
        case "managedAutonomous", "managed_autonomous":
            "Managed: automatic successor creation and continuation"
        case "externalMCPCompatibility", "external_mcp_compatibility":
            "External: handoff persisted; host session control unavailable"
        default:
            "Unavailable"
        }
    }

    private func tokens(_ value: Int?) -> String {
        value.map { "\($0) tokens" } ?? "Unavailable"
    }
}
