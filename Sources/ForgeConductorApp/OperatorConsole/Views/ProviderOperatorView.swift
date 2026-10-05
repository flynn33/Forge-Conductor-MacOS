// ProviderOperatorView.swift
// Native redacted provider endpoint, model, capability, and probe evidence surface.

import SwiftUI
import ForgeConductorCore

struct ProviderOperatorView: View {
    @StateObject private var viewModel: ProviderViewModel
    @State private var showingAdvancedSettings = false
    @State private var inspectedProviderID: ProviderIntegrationID?

    init(client: any OperatorManagerClientProtocol) {
        _viewModel = StateObject(wrappedValue: ProviderViewModel(client: client))
    }

    var body: some View {
        HSplitView {
            providerSelection
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    OperatorHeader(
                        title: "Provider",
                        subtitle: "Choose the provider Forge connects to for MCP governance and automatic continuity.",
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
                            .foregroundStyle(GraphitePalette.textSecondary)
                            .accessibilityIdentifier("provider-probe-notice")
                    }
                    if inspectedDescriptor?.id == .lmStudio {
                        primaryActions
                    }
                }
                .padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let operation = viewModel.currentProviderOperation {
                            providerOperation(operation)
                        }
                        if let descriptor = inspectedDescriptor {
                            providerInspection(descriptor)
                            if descriptor.id == .lmStudio {
                                readiness
                            }
                        }
                        if inspectedDescriptor?.id == .lmStudio, showingAdvancedSettings {
                            VStack(alignment: .leading, spacing: 16) {
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
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GraphitePalette.canvas)
        .task { viewModel.load() }
        .onDisappear {
            viewModel.clearCredentialEntry()
            viewModel.stopObservingProviderOperation()
        }
        .guidedHelpState(viewModel.guidedHelpState, for: .provider)
    }

    private var primaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { providerActionButtons }
            VStack(alignment: .leading, spacing: 8) { providerActionButtons }
        }
    }

    @ViewBuilder
    private var providerActionButtons: some View {
        Button {
            showingAdvancedSettings.toggle()
        } label: {
            Label(
                "LM Studio Advanced",
                systemImage: showingAdvancedSettings ? "chevron.down" : "chevron.right"
            )
        }
        .accessibilityIdentifier("provider-advanced-toggle")
        .buttonStyle(GraphiteButtonStyle(kind: .secondary))

        Button("Connect and Check", action: viewModel.connectAndCheck)
            .buttonStyle(GraphiteButtonStyle(kind: .primary))
            .disabled(viewModel.isBusy || viewModel.hasUnsavedChanges)
            .accessibilityIdentifier("provider-test-connection")

        Button("Run Advanced Probe", action: viewModel.runContractProbe)
            .buttonStyle(GraphiteButtonStyle(kind: .secondary))
            .disabled(viewModel.isBusy || viewModel.hasUnsavedChanges)
            .accessibilityIdentifier("provider-run-contract-probe")
    }

    private var providerSelection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Execution providers")
                .font(.system(size: 15, weight: .semibold))
                .padding(16)
            List(selection: Binding(
                get: { inspectedDescriptor?.id },
                set: { inspectedProviderID = $0 }
            )) {
                ForEach(viewModel.providerDescriptors, id: \.id) { descriptor in
                    HStack(spacing: 10) {
                        Image(systemName: providerIcon(descriptor.id))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(GraphitePalette.info)
                            .frame(width: 24, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(descriptor.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Text(viewModel.isProviderSelected(descriptor.id) ? "Active provider" : "Inspect provider")
                                .font(.system(size: 11))
                                .foregroundStyle(GraphitePalette.textSecondary)
                        }
                        Spacer(minLength: 4)
                        if viewModel.isProviderSelected(descriptor.id) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(GraphitePalette.success)
                                .accessibilityLabel("Active provider")
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(descriptor.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(inspectedDescriptor?.id == descriptor.id ? .isSelected : [])
                    .accessibilityIdentifier("provider-inspect-\(descriptor.id.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            Text("Select a row to inspect. Use Activate in its detail to switch the active provider.")
                .font(.caption)
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .accessibilityIdentifier("provider-selection-guidance")
            if viewModel.isLoadingProviderRegistry, viewModel.integrations == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading provider selection…")
                        .font(.caption)
                        .foregroundStyle(GraphitePalette.textSecondary)
                }
                .padding(16)
            }
        }
        .background(GraphitePalette.sidebar)
    }

    private var inspectedDescriptor: ProviderIntegrationDescriptor? {
        let providerID = inspectedProviderID ?? viewModel.selectedProviderID ?? .lmStudio
        return viewModel.providerDescriptors.first { $0.id == providerID }
    }

    private func providerInspection(_ descriptor: ProviderIntegrationDescriptor) -> some View {
        ProviderSelectionCard(
            descriptor: descriptor,
            integration: viewModel.integration(for: descriptor.id),
            operation: viewModel.currentProviderOperation,
            selected: viewModel.isProviderSelected(descriptor.id),
            actionsDisabled: viewModel.isProviderToggleDisabled(descriptor.id),
            primaryActionAvailable: viewModel.isProviderRepairAvailable(descriptor.id),
            removalDisabled: viewModel.isProviderRemovalDisabled(descriptor.id),
            onToggle: { enabled in viewModel.setProvider(descriptor.id, enabled: enabled) },
            onPrimaryAction: { viewModel.performProviderPrimaryAction(descriptor.id) },
            onRemove: { viewModel.removeProviderIntegration(descriptor.id) }
        )
    }

    private func providerIcon(_ providerID: ProviderIntegrationID) -> String {
        switch providerID {
        case .lmStudio: "cpu"
        case .claudeDesktop: "sparkles"
        case .codexDesktop: "chevron.left.forwardslash.chevron.right"
        case .grokBuild: "terminal"
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
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .textSelection(.enabled)
                }
                if let code = operation.errorCode, !code.isEmpty {
                    LabeledContent("Error code", value: code)
                        .foregroundStyle(GraphitePalette.failure)
                }
                if !operation.isTerminal {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityIdentifier("provider-operation-progress")
                        Text("Forge is applying and verifying the provider integration.")
                            .font(.caption)
                            .foregroundStyle(GraphitePalette.textSecondary)
                        Spacer()
                        Button("Cancel", action: viewModel.cancelCurrentProviderOperation)
                            .disabled(!viewModel.canCancelProviderOperation)
                            .accessibilityIdentifier("provider-operation-cancel")
                    }
                }
            }
        }
        .labeledContentStyle(ProviderFactsStyle())
    }

    private var readiness: some View {
        GroupBox("Model connection") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Status") {
                    OperatorStateBadge(
                        state: providerReadinessState
                    )
                }
                LabeledContent("Endpoint") {
                    OperatorIdentifier(
                        viewModel.provider?.endpoint ?? viewModel.configuration?.endpoint,
                        unavailable: "Not configured"
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Endpoint: \(viewModel.provider?.endpoint ?? viewModel.configuration?.endpoint ?? "Not configured")")
                .accessibilityValue(viewModel.provider?.endpoint ?? viewModel.configuration?.endpoint ?? "Not configured")
                .accessibilityIdentifier("provider-readiness-endpoint")
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
                if viewModel.isProbing {
                    HStack {
                        Button("Cancel", action: viewModel.cancelConnectAndCheck)
                            .accessibilityIdentifier("provider-cancel-connect-and-check")
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .labeledContentStyle(ProviderFactsStyle())
    }

    private var configurationEditor: some View {
        GraphitePanel {
            HStack {
                Text("Provider settings").font(.system(size: 15, weight: .semibold))
                Spacer()
                GuidedHelpButton(context: .providerCredential)
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint")
                        .font(.system(size: 13, weight: .medium))
                    TextField("Endpoint", text: $viewModel.endpoint)
                        .textFieldStyle(GraphiteFieldStyle())
                        .accessibilityIdentifier("provider-endpoint")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model identifier")
                        .font(.system(size: 13, weight: .medium))
                    TextField("Model identifier (optional when exactly one supported model is loaded)", text: $viewModel.modelKey)
                        .textFieldStyle(GraphiteFieldStyle())
                        .accessibilityIdentifier("provider-model-key")
                    Text("Optional when exactly one supported model is loaded.")
                        .font(.system(size: 12))
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                if viewModel.configuration?.endpointMode == .local {
                    Text("Local LM Studio uses the private loopback connection without an operator login or token.")
                        .font(.caption)
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .accessibilityIdentifier("provider-local-no-auth")
                } else {
                    Picker("Credential", selection: $viewModel.credentialAction) {
                        Text("Keep existing credential").tag(ProviderCredentialAction.keep)
                        Text("Replace credential").tag(ProviderCredentialAction.replace)
                        Text("Clear credential").tag(ProviderCredentialAction.clear)
                    }
                    .accessibilityIdentifier("provider-credential-action")
                    if viewModel.credentialAction == .replace {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Linked LM Studio access token")
                                .font(.system(size: 13, weight: .medium))
                            SecureField("Linked LM Studio access token", text: $viewModel.token)
                                .textFieldStyle(GraphiteFieldStyle())
                                .accessibilityIdentifier("provider-token")
                        }
                    }
                    Text(viewModel.configuration?.credentialConfigured == true
                         ? "A linked-provider Keychain credential is configured."
                         : "No linked-provider Keychain credential is configured.")
                        .font(.caption)
                        .foregroundStyle(GraphitePalette.textSecondary)
                }
                HStack {
                    Button("Save", action: viewModel.save)
                        .buttonStyle(GraphiteButtonStyle(kind: .primary))
                        .disabled(viewModel.configuration == nil)
                        .accessibilityIdentifier("provider-save")
                    Button("Refresh Models", action: viewModel.refreshModels)
                        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                        .disabled(viewModel.configuration?.saved != true || viewModel.hasUnsavedChanges)
                        .accessibilityIdentifier("provider-refresh-models")
                }
                Text("Save updates the LM Studio connection used by Forge MCP and continuity. Saving does not test the connection; model loading remains in LM Studio.")
                    .font(.caption).foregroundStyle(GraphitePalette.textSecondary)
                if viewModel.isProbing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("provider-probe-progress")
                }
                if viewModel.hasUnsavedChanges {
                    Text("Save changes before refreshing models or testing this endpoint and model.")
                        .font(.caption).foregroundStyle(GraphitePalette.textSecondary)
                        .accessibilityIdentifier("provider-unsaved-changes")
                }
            }
            .disabled(viewModel.isConfigurationBusy)
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
                        .foregroundStyle(GraphitePalette.textSecondary)
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
                            .foregroundStyle(GraphitePalette.failure)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("provider-last-probe-error")
                    }
                }
            }

            Text("Connect and Check uses one manager-owned path for model discovery, LM Studio recovery, Forge MCP registration, and contract verification.")
                .font(.caption)
                .foregroundStyle(GraphitePalette.textSecondary)
        }
        .labeledContentStyle(ProviderFactsStyle())
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

private struct ProviderFactsStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 144, alignment: .leading)
            configuration.content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderReceiptEvidence: Equatable, Identifiable {
    let key: String
    let label: String
    let value: String

    var id: String { key }

    static func visibleDetails(
        from metadata: [String: String],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [ProviderReceiptEvidence] {
        metadata.compactMap { key, rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !isSensitive(key) else { return nil }
            return ProviderReceiptEvidence(
                key: key,
                label: displayLabel(for: key),
                value: abbreviated(value, for: key, homeDirectory: homeDirectory)
            )
        }
        .sorted {
            if $0.label == $1.label { return $0.key < $1.key }
            return $0.label < $1.label
        }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return ["authorization", "credential", "password", "secret", "token"]
            .contains { normalized.contains($0) }
    }

    private static func displayLabel(for key: String) -> String {
        key.replacingOccurrences(of: "-", with: "_")
            .split(separator: "_")
            .map { component in
                switch component.lowercased() {
                case "app": "App"
                case "cli": "CLI"
                case "id": "ID"
                case "mcp": "MCP"
                case "sha256", "sha": "SHA-256"
                default: component.capitalized
                }
            }
            .joined(separator: " ")
    }

    private static func abbreviated(
        _ value: String,
        for key: String,
        homeDirectory: String
    ) -> String {
        guard key.localizedCaseInsensitiveContains("path"),
              !homeDirectory.isEmpty,
              value == homeDirectory || value.hasPrefix(homeDirectory + "/") else {
            return value
        }
        return "~" + value.dropFirst(homeDirectory.count)
    }
}

private struct ProviderSelectionCard: View {
    let descriptor: ProviderIntegrationDescriptor
    let integration: ProviderIntegrationProviderSnapshot?
    let operation: ProviderIntegrationOperationSnapshot?
    let selected: Bool
    let actionsDisabled: Bool
    let primaryActionAvailable: Bool
    let removalDisabled: Bool
    let onToggle: @MainActor @Sendable (Bool) -> Void
    let onPrimaryAction: () -> Void
    let onRemove: () -> Void

    var body: some View {
        GraphitePanel {
            providerHeading
            VStack(alignment: .leading, spacing: 10) {
                Text(descriptor.detail)
                    .font(.callout)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                LabeledContent("Selection", value: selected ? "Active" : "Inactive")
                LabeledContent(
                    "Availability",
                    value: descriptor.selectable ? "Selectable" : "Not selectable"
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("provider-availability-\(descriptor.id.rawValue)")
                LabeledContent("Setup", value: setupLabel)
                LabeledContent("Execution", value: executionLabel)

                if let receipt = integration?.receipt {
                    LabeledContent("Artifact version", value: receipt.artifactVersion)
                    LabeledContent("Verified", value: receipt.verifiedAt)
                    ForEach(receiptEvidence) { detail in
                        LabeledContent(detail.label, value: detail.value)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(
                                "provider-receipt-\(descriptor.id.rawValue)-\(detail.key)"
                            )
                    }
                }

                if let operation, operation.providerID == descriptor.id {
                    LabeledContent("Latest operation", value: phaseLabel(operation.phase))
                }

                if showsActions {
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { integrationActions }
                        VStack(alignment: .leading, spacing: 8) { integrationActions }
                    }
                }
            }
            .labeledContentStyle(ProviderFactsStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-card-\(descriptor.id.rawValue)")
    }

    private var providerHeading: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(GraphitePalette.info)
            Text(descriptor.displayName)
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            Toggle(
                "Activate \(descriptor.displayName)",
                isOn: Binding(
                    get: { selected },
                    set: { enabled in
                        // These are mutually exclusive selectors. Turning
                        // one on changes the selection; turning the active
                        // choice off cannot leave run admission providerless.
                        onToggle(enabled)
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(actionsDisabled)
            .accessibilityLabel("Activate \(descriptor.displayName)")
            .accessibilityIdentifier("provider-toggle-\(descriptor.id.rawValue)")
        }
        .accessibilityElement(children: .contain)
        .font(.system(size: 15, weight: .semibold))
    }

    @ViewBuilder
    private var integrationActions: some View {
        if primaryActionAvailable {
            Button("Connect and Check", action: onPrimaryAction)
                .buttonStyle(GraphiteButtonStyle(kind: .primary))
                .disabled(actionsDisabled)
                .accessibilityIdentifier("provider-repair-\(descriptor.id.rawValue)")
        }
        if integration?.receipt != nil {
            Button("Remove Integration", role: .destructive, action: onRemove)
                .buttonStyle(GraphiteButtonStyle(kind: .destructive))
                .disabled(removalDisabled)
                .accessibilityIdentifier("provider-remove-\(descriptor.id.rawValue)")
        }
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
        if primaryActionAvailable { return true }
        if integration?.receipt != nil { return true }
        return false
    }

    private var receiptEvidence: [ProviderReceiptEvidence] {
        guard let metadata = integration?.receipt?.metadata else { return [] }
        return ProviderReceiptEvidence.visibleDetails(from: metadata)
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
