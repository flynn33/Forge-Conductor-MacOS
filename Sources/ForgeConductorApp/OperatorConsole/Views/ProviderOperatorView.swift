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
                    isLoading: viewModel.isLoading,
                    onRefresh: viewModel.load
                )
                if let error = viewModel.errorMessage {
                    OperatorErrorBanner(message: error, retry: viewModel.load)
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
                    LabeledContent("Last probe", value: provider.lastProbeAt ?? "Unavailable")
                    if let error = provider.lastProbeError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }

            HStack {
                Button("Test Connection") {}
                Button("Run Contract Probe") {}
            }
            .disabled(true)
            Text("Probe commands are unavailable until the manager publishes an authoritative mutation route; the last persisted result is shown above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func context(_ value: Int?) -> String {
        value.map { "\($0) tokens" } ?? "Unavailable"
    }
}
