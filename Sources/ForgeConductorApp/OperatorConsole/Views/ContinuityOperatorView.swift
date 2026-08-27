// ContinuityOperatorView.swift
// Native rollover operation, context budget, acknowledgment, and recovery detail.

import SwiftUI

struct ContinuityOperatorView: View {
    @StateObject private var viewModel: ContinuityViewModel

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
                            Text(operation.state.replacingOccurrences(of: "_", with: " "))
                                .lineLimit(1)
                            Text("Attempt \(operation.attempt) · \(operation.runID)")
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
                        subtitle: "Durable budget, checkpoint, successor, acknowledgment, and fencing state",
                        isLoading: viewModel.isLoading,
                        onRefresh: viewModel.load
                    )
                    if let error = viewModel.errorMessage {
                        OperatorErrorBanner(message: error, retry: viewModel.load)
                    }
                    if let operation = viewModel.selectedOperation {
                        operationDetail(operation)
                    } else if viewModel.errorMessage == nil, !viewModel.isLoading {
                        ContentUnavailableView(
                            "No Continuity Operations",
                            systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                            description: Text("The manager has no bounded rollover operation to display.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(20)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { viewModel.load() }
        .accessibilityIdentifier("continuity-operator-view")
    }

    private func operationDetail(_ operation: OperatorContinuity) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Operation") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Mode", value: modeLabel(operation.mode))
                    LabeledContent("State") {
                        OperatorStateBadge(state: displayedState(operation))
                            .accessibilityIdentifier("rollover-operation-state")
                    }
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
                                    Text("\(event.timestamp) · \(event.kind)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Checkpoint Now") {}
                Button("Request Early Rollover") {}
                    .accessibilityIdentifier("rollover-command")
                Spacer()
            }
            .disabled(true)
            Text("Administrative checkpoint and rollover commands are unavailable until the manager publishes authoritative mutation routes. Display state remains read-only.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
