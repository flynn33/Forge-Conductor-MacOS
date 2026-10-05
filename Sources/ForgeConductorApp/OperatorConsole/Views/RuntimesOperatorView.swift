// RuntimesOperatorView.swift
// Native shell policy, independent runtime capability, and bounded job history surface.

import SwiftUI
import ForgeConductorCore

struct RuntimesOperatorView: View {
    @StateObject private var viewModel: RuntimesViewModel
    @State private var showingAdvancedSettings = false

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: RuntimesViewModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OperatorHeader(
                title: "Runtimes",
                subtitle: "Programs needed by the selected task and the results of its durable jobs",
                isLoading: viewModel.isLoading,
                titleAccessibilityIdentifier: "detail-runtimes",
                subtitleAccessibilityIdentifier: "runtimes-operator-view",
                onRefresh: viewModel.load
            )
            if let error = viewModel.errorMessage {
                OperatorErrorBanner(message: error, retry: viewModel.load)
            }
            if let notice = viewModel.notice {
                OperatorNoticeBanner(message: notice)
            }
            HSplitView {
                List(selection: $viewModel.selectedJobID) {
                    Section("Active and recent jobs") {
                        ForEach(viewModel.jobs) { job in
                            HStack(spacing: 10) {
                                Image(systemName: "terminal")
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.commandSummary).lineLimit(1)
                                    Text("\(job.runtimeKind) · \(job.state)")
                                        .font(.caption)
                                        .foregroundStyle(GraphitePalette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(job.jobID)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("runtime-job-row-\(job.jobID)")
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(GraphitePalette.sidebar)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        taskRequirements
                        if let job = viewModel.selectedJob {
                            jobDetail(job)
                        } else if !viewModel.jobs.isEmpty {
                            Text("Select a job to inspect its durable output and exit state.")
                                .foregroundStyle(GraphitePalette.textSecondary)
                        } else {
                            GraphitePanel(title: "Jobs") {
                                Text("No active or recent runtime jobs were published.")
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Button {
                            showingAdvancedSettings.toggle()
                        } label: {
                            Label(
                                "Advanced runtime settings",
                                systemImage: showingAdvancedSettings ? "chevron.down" : "chevron.right"
                            )
                        }
                        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("runtime-advanced-toggle")
                        if showingAdvancedSettings {
                            VStack(alignment: .leading, spacing: 16) {
                                shellPolicy
                                capabilityList
                                runtimePolicy
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(16)
                }
                .background(GraphitePalette.canvas)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .background(GraphitePalette.canvas)
        .task { viewModel.load() }
        .guidedHelpState(viewModel.guidedHelpState, for: .runtimes)
    }

    private var shellPolicy: some View {
        GraphitePanel(title: "Application-wide shell policy") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Shell enabled",
                    isOn: Binding(
                        get: { viewModel.settings?.shellEnabled ?? false },
                        set: { enabled in
                            viewModel.setShellEnabled(enabled)
                        }
                    )
                )
                .disabled(viewModel.settings == nil || viewModel.isSavingShellPolicy)
                .accessibilityIdentifier("runtime-shell-enabled")
                LabeledContent("Effective policy", value: effectivePolicy)
                LabeledContent("Policy origin", value: viewModel.settings?.shellPolicyOrigin ?? "Unavailable")
                LabeledContent("Default timeout", value: timeoutLabel)
                LabeledContent("Migration", value: migrationLabel)
                    .accessibilityIdentifier("runtime-shell-migration")
            }
        }
    }

    private var taskRequirements: some View {
        GraphitePanel(title: "Runtimes for the selected task") {
            VStack(alignment: .leading, spacing: 10) {
                if let taskID = viewModel.runtimePolicy?.selectedTaskID {
                    LabeledContent("Task") { OperatorIdentifier(taskID) }
                } else {
                    Text("No task runtime is selected. Missing optional runtimes do not block LM Studio chat work.")
                        .foregroundStyle(GraphitePalette.textSecondary)
                }
                ForEach(viewModel.runtimePolicy?.requirements ?? [], id: \.runtime) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runtimeName(item.runtime))
                            Text(item.reason)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(GraphitePalette.textSecondary)
                            if let action = item.recoveryAction {
                                Text(action)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .foregroundStyle(GraphitePalette.warning)
                            }
                        }
                        Spacer()
                        Text(requirementName(item.requirement))
                            .font(.caption)
                        OperatorStateBadge(state: item.availability.rawValue)
                    }
                    .accessibilityIdentifier("runtime-requirement-\(item.runtime.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("runtime-task-requirements")
    }

    private var capabilityList: some View {
        GraphitePanel(title: "Runtime capabilities") {
            VStack(alignment: .leading, spacing: 9) {
                runtimeCapability("Direct process", id: "direct", capability: viewModel.runtimePolicy?.direct)
                runtimeCapability("zsh", id: "zsh", capability: viewModel.runtimePolicy?.zsh)
                runtimeCapability("Bash", id: "bash", capability: viewModel.runtimePolicy?.bash)
                runtimeCapability("Python", id: "python", capability: viewModel.runtimePolicy?.python)
                runtimeCapability("PowerShell", id: "powershell", capability: viewModel.runtimePolicy?.powershell)
            }
        }
        .accessibilityIdentifier("runtime-capabilities-panel")
    }

    private var runtimePolicy: some View {
        GraphitePanel(title: "Execution limits") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Job concurrency", value: viewModel.runtimePolicy.map { "\($0.maximumConcurrentJobs)" } ?? "Unavailable")
                LabeledContent("Default timeout", value: viewModel.runtimePolicy.map { "\($0.defaultTimeoutSeconds)s" } ?? "Unavailable")
                LabeledContent("Inline output quota", value: viewModel.runtimePolicy.map { OperatorFormat.bytes(UInt64($0.maximumInlineOutputBytes)) } ?? "Unavailable")
                LabeledContent("Artifact quota per job", value: viewModel.runtimePolicy.map { OperatorFormat.bytes(UInt64($0.maximumArtifactBytesPerJob)) } ?? "Unavailable")
                LabeledContent("Network policy", value: viewModel.runtimePolicy?.networkPolicy ?? "Unavailable")
            }
        }
        .accessibilityIdentifier("runtime-execution-limits")
    }

    private func jobDetail(_ job: OperatorRuntimeJob) -> some View {
        GraphitePanel {
            HStack {
                Text("Selected job").font(.system(size: 15, weight: .semibold))
                Spacer()
                GuidedHelpButton(context: .runtimeJob)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent("State") { OperatorStateBadge(state: job.state) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("State")
                    .accessibilityIdentifier("runtime-job-state")
                LabeledContent("Purpose", value: job.commandSummary)
                LabeledContent("Result", value: jobResult(job))
                LabeledContent("Runtime", value: job.runtimeKind)
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent("Job ID") { OperatorIdentifier(job.jobID) }
                        LabeledContent("Project") { OperatorIdentifier(job.projectID) }
                        LabeledContent("Generation", value: "\(job.projectGeneration)")
                        LabeledContent("Run") { OperatorIdentifier(job.runID) }
                        LabeledContent("Working directory") { OperatorIdentifier(job.canonicalWorkingDirectory) }
                        LabeledContent("Timeout", value: "\(job.timeoutSeconds)s")
                        LabeledContent("Output bytes", value: OperatorFormat.bytes(job.outputBytes))
                        LabeledContent("Output artifact") { OperatorIdentifier(job.outputArtifactID) }
                    }
                    .padding(.top, 6)
                }
                .accessibilityIdentifier("runtime-job-technical-details")
                if let error = job.errorSummary {
                    Text(error).font(.caption).foregroundStyle(GraphitePalette.failure).textSelection(.enabled)
                }
                Button("Cancel Job", role: .destructive) {
                    viewModel.cancelSelectedJob()
                }
                    .buttonStyle(GraphiteButtonStyle(kind: .destructive))
                    .disabled(!viewModel.canCancelSelectedJob)
                    .help(
                        viewModel.canCancelSelectedJob
                            ? "Persist cancellation for this queued or running job."
                            : "Only queued or running jobs can be cancelled."
                    )
                    .accessibilityIdentifier("runtime-job-cancel")
            }
        }
    }

    private func runtimeCapability(
        _ label: String,
        id: String,
        capability: OperatorRuntimeExecutable?
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(capability?.path ?? "Executable path unavailable")
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(capability?.version ?? "Version unavailable")
                    .font(.caption2)
                    .foregroundStyle(GraphitePalette.textSecondary)
            }
            Spacer()
            OperatorStateBadge(state: capability?.status.rawValue ?? "unknown")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runtime-capability-\(id)")
    }

    private var effectivePolicy: String {
        guard let settings = viewModel.settings else { return "Unavailable" }
        return settings.shellEnabled ? "Enabled for bound project sessions" : "Disabled by persisted policy"
    }

    private var timeoutLabel: String {
        viewModel.settings.map { "\($0.shellTimeoutSec)s" } ?? "Unavailable"
    }

    private var migrationLabel: String {
        guard let settings = viewModel.settings else { return "Unavailable" }
        let receipt = settings.shellMigrationReceiptValid ? "receipt verified" : "receipt unavailable"
        return "\(settings.shellMigrationState) · \(receipt)"
    }

    private func runtimeName(_ runtime: RuntimeRequirementIdentifier) -> String {
        switch runtime {
        case .directProcess: "Direct process"
        case .zsh: "zsh"
        case .bash: "Bash"
        case .python: "Python"
        case .powershell: "PowerShell"
        }
    }

    private func requirementName(_ requirement: RuntimeRequirement) -> String {
        switch requirement {
        case .required: "Required"
        case .optional: "Optional"
        case .notNeeded: "Not needed"
        }
    }

    private func jobResult(_ job: OperatorRuntimeJob) -> String {
        if let exitCode = job.exitCode {
            return "\(job.state) · exit \(exitCode)"
        }
        return job.errorSummary ?? job.state
    }
}
