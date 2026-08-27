// RuntimesOperatorView.swift
// Native shell policy, independent runtime capability, and bounded job history surface.

import SwiftUI

struct RuntimesOperatorView: View {
    @StateObject private var viewModel: RuntimesViewModel

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
                        subtitle: "Effective shell policy, independent executable capabilities, and durable jobs",
                        isLoading: viewModel.isLoading,
                        onRefresh: viewModel.load
                    )
                    if let error = viewModel.errorMessage {
                        OperatorErrorBanner(message: error, retry: viewModel.load)
                    }
                    if let notice = viewModel.notice {
                        OperatorNoticeBanner(message: notice)
                    }
                    shellPolicy
                    capabilityList
                    runtimePolicy
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
        .accessibilityIdentifier("runtimes-operator-view")
    }

    private var shellPolicy: some View {
        GroupBox("Project shell policy") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Shell enabled",
                    isOn: Binding(
                        get: { viewModel.settings?.shellEnabled ?? false },
                        set: viewModel.setShellEnabled
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
        GroupBox("Selected job") {
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent("State") { OperatorStateBadge(state: job.state) }
                LabeledContent("Job ID") { OperatorIdentifier(job.jobID) }
                LabeledContent("Runtime", value: job.runtimeKind)
                LabeledContent("Project") { OperatorIdentifier(job.projectID) }
                LabeledContent("Generation", value: "\(job.projectGeneration)")
                LabeledContent("Run") { OperatorIdentifier(job.runID) }
                LabeledContent("Working directory") { OperatorIdentifier(job.canonicalWorkingDirectory) }
                LabeledContent("Command summary", value: job.commandSummary)
                LabeledContent("Timeout", value: "\(job.timeoutSeconds)s")
                LabeledContent("Exit", value: job.exitCode.map(String.init) ?? "Unavailable")
                LabeledContent("Output bytes", value: OperatorFormat.bytes(job.outputBytes))
                LabeledContent("Output artifact") { OperatorIdentifier(job.outputArtifactID) }
                if let error = job.errorSummary {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Button("Cancel Job", role: .destructive) {}
                    .disabled(true)
                    .help("The manager does not advertise a runtime-job cancel command in this build.")
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
                Text(capability?.path ?? "Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(capability?.version ?? "Version unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            OperatorStateBadge(state: capability?.available == true ? "available" : "unavailable")
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
}
