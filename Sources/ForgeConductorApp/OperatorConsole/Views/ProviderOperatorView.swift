// ProviderOperatorView.swift
// Native redacted provider endpoint, model, capability, and probe evidence surface.

import SwiftUI

struct ProviderOperatorView: View {
    @StateObject private var viewModel: ProviderViewModel

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ProviderViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OperatorHeader(
                    title: "Provider",
                    subtitle: "Redacted endpoint, model instance, context, tools, credentials, and contract health",
                    isLoading: viewModel.isLoading || viewModel.isProbing,
                    onRefresh: viewModel.load
                )
                if let error = viewModel.errorMessage {
                    OperatorErrorBanner(message: error, retry: viewModel.load)
                }
                if let notice = viewModel.noticeMessage {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("provider-probe-notice")
                }
                if let provider = viewModel.provider {
                    providerDetail(provider)
                }
            }
            .padding(20)
        }
        .task { viewModel.load() }
        .accessibilityIdentifier("provider-operator-view")
    }

    private func providerDetail(_ provider: OperatorProvider) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Health") {
                        OperatorStateBadge(state: provider.health)
                            .accessibilityIdentifier("provider-health")
                    }
                    LabeledContent("Adapter", value: provider.adapterID ?? "Unavailable")
                    LabeledContent("Provider", value: provider.providerID ?? "Unavailable")
                    LabeledContent("Endpoint") { OperatorIdentifier(provider.endpoint) }
                    LabeledContent("Loopback", value: OperatorFormat.yesNo(provider.loopback))
                    LabeledContent("TLS", value: OperatorFormat.yesNo(provider.tls))
                    LabeledContent("API mode", value: provider.apiMode ?? "Unavailable")
                }
            }

            GroupBox("Authentication") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Authentication enabled", value: OperatorFormat.yesNo(provider.authenticationEnabled))
                    LabeledContent("Keychain credential configured", value: OperatorFormat.yesNo(provider.credentialConfigured))
                    Text("Credential values are never displayed or returned by the operator snapshot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Loaded model") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Model", value: provider.modelKey ?? "Unavailable")
                    LabeledContent("Instance", value: provider.instanceID ?? "Unavailable")
                    LabeledContent("Active context", value: context(provider.activeContextLength))
                    LabeledContent("Maximum context", value: context(provider.maximumContextLength))
                    LabeledContent("Tool use", value: OperatorFormat.yesNo(provider.toolUseCapable))
                }
            }

            GroupBox("Lifecycle and contract") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Lifecycle management", value: OperatorFormat.yesNo(provider.lifecycleManagementEnabled))
                    LabeledContent("Idle TTL", value: provider.idleTTLSeconds.map { "\($0)s" } ?? "Unavailable")
                    LabeledContent("Contract fingerprint") { OperatorIdentifier(provider.contractFingerprint) }
                    LabeledContent("Last probe mode", value: provider.lastProbeMode ?? "Unavailable")
                    LabeledContent(
                        "Probe result storage",
                        value: probeStorage(provider.probeResultStorage)
                    )
                    LabeledContent("Last probe", value: provider.lastProbeAt ?? "Unavailable")
                    if let error = provider.lastProbeError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("provider-last-probe-error")
                    }
                }
            }

            HStack {
                Button("Test Connection", action: viewModel.testConnection)
                    .accessibilityIdentifier("provider-test-connection")
                Button("Run Contract Probe", action: viewModel.runContractProbe)
                    .accessibilityIdentifier("provider-run-contract-probe")
                if viewModel.isProbing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("provider-probe-progress")
                }
            }
            .disabled(viewModel.isLoading || viewModel.isProbing)
            Text("Connection testing performs a real provider probe. Contract probing also verifies the stateful response, tool, usage, identity, and idempotency capabilities required by Forge.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func context(_ value: Int?) -> String {
        value.map { "\($0) tokens" } ?? "Unavailable"
    }

    private func probeStorage(_ value: String?) -> String {
        switch value {
        case "memory_only": "In memory only (cleared on manager restart)"
        case let value?: value
        case nil: "Unavailable"
        }
    }
}
