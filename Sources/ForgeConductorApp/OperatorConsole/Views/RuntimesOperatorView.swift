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
        NavigationSplitView {
            List(selection: $viewModel.selectedJobID) {
                Section("Active and recent jobs") {
                    ForEach(viewModel.jobs) { job in
                        HStack(spacing: 10) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.commandSummary).lineLimit(1)
                                Text("\(job.runtimeKind) · \(job.state)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(job.jobID)
                        .accessibilityIdentifier("runtime-job-row-\(job.jobID)")
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                    taskRequirements
                    Button {
                        showingAdvancedSettings.toggle()
                    } label: {
                        Label(
                            "Advanced runtime settings",
                            systemImage: showingAdvancedSettings ? "chevron.down" : "chevron.right"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("runtime-advanced-toggle")
                    if showingAdvancedSettings {
                        VStack(alignment: .leading, spacing: 16) {
                            shellPolicy
                            capabilityList
                            runtimePolicy
                        }
                        .padding(.top, 8)
                    }
                    if let job = viewModel.selectedJob {
                        jobDetail(job)
                    } else if !viewModel.jobs.isEmpty {
                        Text("Select a job to inspect its durable output and exit state.")
                            .foregroundStyle(.secondary)
                    } else {
                        GroupBox("Jobs") {
                            Text("No active or recent runtime jobs were published.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { viewModel.load() }
        .guidedHelpState(viewModel.guidedHelpState, for: .runtimes)
    }

    private var shellPolicy: some View {
        GroupBox("Application-wide shell policy") {
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
        GroupBox("Runtimes for the selected task") {
            VStack(alignment: .leading, spacing: 10) {
                if let taskID = viewModel.runtimePolicy?.selectedTaskID {
                    LabeledContent("Task") { OperatorIdentifier(taskID) }
                } else {
                    Text("No managed task is selected. Missing optional runtimes do not block a task.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.runtimePolicy?.requirements ?? [], id: \.runtime) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runtimeName(item.runtime))
                            Text(item.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let action = item.recoveryAction {
                                Text(action)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
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
    }

    private var capabilityList: some View {
        GroupBox("Runtime capabilities") {
            VStack(alignment: .leading, spacing: 9) {
                runtimeCapability("Direct process", id: "direct", capability: viewModel.runtimePolicy?.direct)
                runtimeCapability("zsh", id: "zsh", capability: viewModel.runtimePolicy?.zsh)
                runtimeCapability("Bash", id: "bash", capability: viewModel.runtimePolicy?.bash)
                runtimeCapability("Python", id: "python", capability: viewModel.runtimePolicy?.python)
                runtimeCapability("PowerShell", id: "powershell", capability: viewModel.runtimePolicy?.powershell)
            }
        }
    }

    private var runtimePolicy: some View {
        GroupBox("Execution limits") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Job concurrency", value: viewModel.runtimePolicy.map { "\($0.maximumConcurrentJobs)" } ?? "Unavailable")
                LabeledContent("Default timeout", value: viewModel.runtimePolicy.map { "\($0.defaultTimeoutSeconds)s" } ?? "Unavailable")
                LabeledContent("Inline output quota", value: viewModel.runtimePolicy.map { OperatorFormat.bytes(UInt64($0.maximumInlineOutputBytes)) } ?? "Unavailable")
                LabeledContent("Artifact quota per job", value: viewModel.runtimePolicy.map { OperatorFormat.bytes(UInt64($0.maximumArtifactBytesPerJob)) } ?? "Unavailable")
                LabeledContent("Network policy", value: viewModel.runtimePolicy?.networkPolicy ?? "Unavailable")
            }
        }
    }

    private func jobDetail(_ job: OperatorRuntimeJob) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent("State") { OperatorStateBadge(state: job.state) }
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
                if let error = job.errorSummary {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Button("Cancel Job", role: .destructive) {
                    viewModel.cancelSelectedJob()
                }
                    .disabled(!viewModel.canCancelSelectedJob)
                    .help(
                        viewModel.canCancelSelectedJob
                            ? "Persist cancellation for this queued or running job."
                            : "Only queued or running jobs can be cancelled."
                    )
                    .accessibilityIdentifier("runtime-job-cancel")
            }
        } label: {
            HStack {
                Text("Selected job")
                Spacer()
                GuidedHelpButton(context: .runtimeJob)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(capability?.version ?? "Version unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            OperatorStateBadge(state: capability?.status.rawValue ?? "unknown")
        }
        .accessibilityIdentifier("runtime-capability-\(id)")
    }

    private var effectivePolicy: String {
        guard let settings = viewModel.settings else { return "Unavailable" }
        return settings.shellEnabled ? "Enabled for authorized project bindings" : "Disabled by persisted policy"
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
