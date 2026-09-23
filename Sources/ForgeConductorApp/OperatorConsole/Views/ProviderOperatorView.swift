// ProviderOperatorView.swift
// Native redacted provider endpoint, model, capability, and probe evidence surface.

import SwiftUI
import ForgeConductorCore

struct ProviderOperatorView: View {
    @StateObject private var viewModel: ProviderViewModel
    @State private var showingAdvancedSettings = false

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ProviderViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OperatorHeader(
                    title: "Provider",
                    subtitle: "Choose one execution provider. Forge manages LM Studio inference and orchestrates work in supported desktop coding hosts.",
                    isLoading: viewModel.isBusy,
                    titleAccessibilityIdentifier: "detail-provider",
                    subtitleAccessibilityIdentifier: "provider-operator-view",
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
                providerSelection
                if let operation = viewModel.currentProviderOperation {
                    providerOperation(operation)
                }
                Button {
                    showingAdvancedSettings.toggle()
                } label: {
                    Label(
                        "LM Studio Advanced",
                        systemImage: showingAdvancedSettings ? "chevron.down" : "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("provider-advanced-toggle")
                if showingAdvancedSettings {
                    VStack(alignment: .leading, spacing: 16) {
                        readiness
                        configurationEditor
                        if let provider = viewModel.provider {
                            providerDetail(provider)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .task { viewModel.load() }
        .onDisappear {
            viewModel.clearCredentialEntry()
            viewModel.stopObservingProviderOperation()
        }
        .guidedHelpState(viewModel.guidedHelpState, for: .provider)
    }

    private var providerSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Execution provider")
                    .font(.headline)
                Spacer()
                if let selected = viewModel.selectedProviderID,
                   let descriptor = viewModel.providerDescriptors.first(where: { $0.id == selected }) {
                    Text("Active: \(descriptor.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No active provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(viewModel.providerDescriptors, id: \.displayName) { descriptor in
                    ProviderSelectionCard(
                        descriptor: descriptor,
                        integration: viewModel.integration(for: descriptor.id),
                        operation: viewModel.currentProviderOperation,
                        selected: viewModel.isProviderSelected(descriptor.id),
                        actionsDisabled: viewModel.isProviderToggleDisabled(descriptor.id),
                        repairAvailable: viewModel.isProviderRepairAvailable(descriptor.id),
                        removalDisabled: viewModel.isProviderRemovalDisabled(descriptor.id),
                        onToggle: { enabled in
                            viewModel.setProvider(descriptor.id, enabled: enabled)
                        },
                        onRepair: {
                            viewModel.performProviderPrimaryAction(descriptor.id)
                        },
                        onRemove: {
                            viewModel.removeProviderIntegration(descriptor.id)
                        }
                    )
                }
            }

            if viewModel.isLoadingProviderRegistry, viewModel.integrations == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading provider selection…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func providerOperation(
        _ operation: ProviderIntegrationOperationSnapshot
    ) -> some View {
        GroupBox("Provider setup") {
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent("Operation", value: operation.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                if let providerID = operation.providerID,
                   let descriptor = viewModel.providerDescriptors.first(where: { $0.id == providerID }) {
                    LabeledContent("Provider", value: descriptor.displayName)
                }
                LabeledContent("Phase", value: operation.phase.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                if let detail = operation.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let code = operation.errorCode, !code.isEmpty {
                    LabeledContent("Error code", value: code)
                        .foregroundStyle(.red)
                }
                if !operation.isTerminal {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityIdentifier("provider-operation-progress")
                        Text("Forge is applying and verifying the provider integration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", action: viewModel.cancelCurrentProviderOperation)
                            .disabled(!viewModel.canCancelProviderOperation)
                            .accessibilityIdentifier("provider-operation-cancel")
                    }
                }
            }
        }
    }

    private var readiness: some View {
        GroupBox("Model connection") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Status") {
                    OperatorStateBadge(
                        state: providerReadinessState
                    )
                }
                LabeledContent("Endpoint", value: "Local LM Studio")
                LabeledContent(
                    "Model",
                    value: viewModel.provider?.modelKey
                        ?? viewModel.configuration?.modelKey
                        ?? "Not selected"
                )
                LabeledContent(
                    "Tool use",
                    value: viewModel.provider?.toolUseCapable == true ? "Available" : "Not checked"
                )
                LabeledContent(
                    "Context",
                    value: context(viewModel.provider?.activeContextLength)
                )
                LabeledContent(
                    "Last checked",
                    value: viewModel.provider?.lastProbeAt ?? "Not checked"
                )
                if let action = viewModel.preparation?.recoveryAction, action != .none {
                    LabeledContent("Next action", value: recoveryActionLabel(action))
                }
                HStack {
                    Button("Connect and Check", action: viewModel.connectAndCheck)
                        .disabled(viewModel.isBusy || viewModel.hasUnsavedChanges)
                        .accessibilityIdentifier("provider-test-connection")
                    if viewModel.isProbing {
                        Button("Cancel", action: viewModel.cancelConnectAndCheck)
                            .accessibilityIdentifier("provider-cancel-connect-and-check")
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private var configurationEditor: some View {
        GroupBox {
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
        } label: {
            HStack {
                Text("Provider settings")
                Spacer()
                GuidedHelpButton(context: .providerCredential)
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

            Text("Connect and Check performs model discovery, local LM Studio recovery when needed, and the full managed-provider contract probe. The separate probe remains available here for advanced diagnosis.")
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

    private var providerReadinessState: String {
        if viewModel.isProbing { return "checking" }
        if viewModel.preparation?.state == .ready
            || viewModel.provider?.health == "contract_valid" {
            return "ready"
        }
        return viewModel.provider?.health ?? "not_checked"
    }

    private func recoveryActionLabel(_ action: ProviderPreparationRecoveryAction) -> String {
        switch action {
        case .none: "No action required"
        case .startService: "Start LM Studio, then choose Connect and Check again"
        case .selectModel: "Select one compatible loaded model"
        case .loadModel: "Load the selected model in LM Studio"
        case .installCompatibleModel: "Install a tool-capable model in LM Studio"
        case .supplyCredential: "Supply the required provider credential"
        case .retry: "Retry Connect and Check"
        }
    }
}

private struct ProviderSelectionCard: View {
    let descriptor: ProviderIntegrationDescriptor
    let integration: ProviderIntegrationProviderSnapshot?
    let operation: ProviderIntegrationOperationSnapshot?
    let selected: Bool
    let actionsDisabled: Bool
    let repairAvailable: Bool
    let removalDisabled: Bool
    let onToggle: (Bool) -> Void
    let onRepair: () -> Void
    let onRemove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(descriptor.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                LabeledContent("Selection", value: selected ? "Active" : "Inactive")
                LabeledContent("Setup", value: setupLabel)
                LabeledContent("Execution", value: executionLabel)

                if let receipt = integration?.receipt {
                    LabeledContent("Artifact version", value: receipt.artifactVersion)
                    LabeledContent("Verified", value: receipt.verifiedAt)
                    ForEach(receiptConnectionDetails, id: \.key) { detail in
                        LabeledContent(detail.label, value: detail.value)
                    }
                }

                if let operation, operation.providerID == descriptor.id {
                    LabeledContent("Latest operation", value: phaseLabel(operation.phase))
                }

                if showsActions {
                    Divider()
                    HStack(spacing: 10) {
                        if repairAvailable {
                            Button(repairActionLabel, action: onRepair)
                                .disabled(actionsDisabled)
                                .accessibilityIdentifier("provider-repair-\(descriptor.id.rawValue)")
                        }
                        if integration?.receipt != nil {
                            Button("Remove Integration", role: .destructive, action: onRemove)
                                .disabled(removalDisabled)
                                .accessibilityIdentifier("provider-remove-\(descriptor.id.rawValue)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(descriptor.displayName)
                    .font(.headline)
                Spacer()
                Toggle(
                    "Activate \(descriptor.displayName)",
                    isOn: Binding(
                        get: { selected },
                        set: onToggle
                    )
                )
                .labelsHidden()
                .disabled(actionsDisabled)
                .accessibilityLabel("Activate \(descriptor.displayName)")
                .accessibilityIdentifier("provider-toggle-\(descriptor.id.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-card-\(descriptor.id.rawValue)")
    }

    private var setupLabel: String {
        switch integration?.setupState ?? .notConfigured {
        case .configured: "Configured"
        case .notConfigured: "Not configured"
        }
    }

    private var executionLabel: String {
        switch descriptor.executionStrategy {
        case .managedProviderPush: "Managed model execution"
        case .desktopPluginPull: "Desktop host orchestration"
        }
    }

    private var showsActions: Bool {
        if integration?.receipt != nil { return true }
        guard repairAvailable else { return false }
        if selected { return true }
        guard let operation, operation.providerID == descriptor.id else { return false }
        return operation.phase == .failedRecoverable || operation.phase == .awaitingUserAction
    }

    private var repairActionLabel: String {
        descriptor.executionStrategy == .managedProviderPush
            ? "Connect and Check"
            : "Repair Integration"
    }

    private var receiptConnectionDetails: [(key: String, label: String, value: String)] {
        guard let metadata = integration?.receipt?.metadata else { return [] }
        return metadata
            .filter { key, _ in
                let normalized = key.lowercased()
                return normalized.contains("mcp") || normalized.contains("connection")
            }
            .map { key, value in
                (
                    key: key,
                    label: "Receipt \(key.replacingOccurrences(of: "_", with: " ").capitalized)",
                    value: value
                )
            }
            .sorted { $0.key < $1.key }
    }

    private var iconName: String {
        switch descriptor.id {
        case .lmStudio: "cpu"
        case .claudeDesktop: "sparkles"
        case .codexDesktop: "chevron.left.forwardslash.chevron.right"
        case .grokBuild: "terminal"
        }
    }

    private func phaseLabel(_ phase: ProviderIntegrationOperationPhase) -> String {
        phase.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
