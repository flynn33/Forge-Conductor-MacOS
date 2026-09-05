// ProviderOperatorView.swift
// Native redacted provider endpoint, model, capability, and probe evidence surface.

import SwiftUI
import ForgeConductorCore

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
                    isLoading: viewModel.isBusy,
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
                configurationEditor
                if let provider = viewModel.provider {
                    providerDetail(provider)
                }
            }
            .padding(20)
        }
        .task { viewModel.load() }
        .onDisappear { viewModel.clearCredentialEntry() }
        .accessibilityIdentifier("provider-operator-view")
    }

    private var configurationEditor: some View {
        GroupBox("Provider settings") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Endpoint", text: $viewModel.endpoint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("provider-endpoint")
                TextField("Model identifier (optional when exactly one supported model is loaded)", text: $viewModel.modelKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("provider-model-key")
                if !viewModel.availableModels.isEmpty {
                    Picker("Available models", selection: $viewModel.modelKey) {
                        Text("Choose a model").tag("")
                        if !viewModel.modelKey.isEmpty, !viewModel.availableModels.contains(where: { $0.key == viewModel.modelKey }) {
                            Text(viewModel.modelKey).tag(viewModel.modelKey)
                        }
                        ForEach(viewModel.availableModels, id: \.key) { model in
                            Text(model.key + (model.loaded ? " (loaded)" : " (unloaded)") + (model.toolUseCapable ? "" : " — no tool use"))
                                .tag(model.key)
                        }
                    }
                    .accessibilityIdentifier("provider-model-selection")
                }
                Picker("Credential", selection: $viewModel.credentialAction) {
                    Text("Keep existing credential").tag(ProviderCredentialAction.keep)
                    Text("Replace credential").tag(ProviderCredentialAction.replace)
                    Text("Clear credential").tag(ProviderCredentialAction.clear)
                }
                .accessibilityIdentifier("provider-credential-action")
                if viewModel.credentialAction == .replace {
                    SecureField("LM Studio access token", text: $viewModel.token)
                        .accessibilityIdentifier("provider-token")
                }
                Text(viewModel.configuration?.credentialConfigured == true ? "A Keychain credential is configured." : "No Keychain credential is configured.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save", action: viewModel.save)
                        .disabled(viewModel.configuration == nil)
                        .accessibilityIdentifier("provider-save")
                    Button("Refresh Models", action: viewModel.refreshModels)
                        .disabled(viewModel.configuration?.saved != true || viewModel.hasUnsavedChanges)
                        .accessibilityIdentifier("provider-refresh-models")
                }
                Text("Save applies to future managed runs. Finish or cancel existing runs before changing settings. Saving does not test the connection; model loading remains in LM Studio.")
                    .font(.caption).foregroundStyle(.secondary)
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
                .disabled(viewModel.isBusy || viewModel.hasUnsavedChanges)
                if viewModel.hasUnsavedChanges {
                    Text("Save changes before refreshing models or testing this endpoint and model.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("provider-unsaved-changes")
                }
            }
            .disabled(viewModel.isBusy)
            if viewModel.isSaving || viewModel.isFetchingModels {
                Button("Cancel request", action: viewModel.cancelConfigurationRequest)
                    .accessibilityIdentifier("provider-cancel-configuration")
            }
        }
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
