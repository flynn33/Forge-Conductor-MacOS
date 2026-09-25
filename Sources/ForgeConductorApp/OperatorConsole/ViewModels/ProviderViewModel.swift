// ProviderViewModel.swift
// Main-actor provider selection and LM Studio capability projection without exposing credential material.

import Foundation
import ForgeConductorCore

@MainActor
final class ProviderViewModel: ObservableObject {
    private static let maximumOperationPollAttempts = 120
    private static let maximumConsecutivePollFailures = 3

    // Legacy LM Studio connection state remains independent from the provider registry.
    @Published private(set) var provider: OperatorProvider?
    @Published private(set) var isLoading = false
    @Published private(set) var isProbing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?

    @Published var endpoint = "http://127.0.0.1:1234"
    @Published var modelKey = ""
    @Published var token = ""
    @Published var credentialAction: ProviderCredentialAction = .keep
    @Published private(set) var configuration: ProviderConfigurationSnapshot?
    @Published private(set) var availableModels: [ProviderAvailableModel] = []
    @Published private(set) var isSaving = false
    @Published private(set) var isFetchingModels = false
    @Published private(set) var preparation: ManagerProviderPreparationResult?

    // Provider registry and durable setup-operation state.
    @Published private(set) var integrations: ProviderIntegrationsSnapshot?
    @Published private(set) var currentProviderOperation: ProviderIntegrationOperationSnapshot?
    @Published private(set) var isLoadingProviderRegistry = false
    @Published private(set) var isSubmittingProviderMutation = false

    var isBusy: Bool {
        isLoading || isProbing || isSaving || isFetchingModels
            || isLoadingProviderRegistry || isSubmittingProviderMutation
    }

    var hasUnsavedChanges: Bool {
        guard let configuration else { return false }
        return endpoint != configuration.endpoint || modelKey != (configuration.modelKey ?? "")
            || credentialAction != .keep
    }

    var selectedProviderID: ProviderIntegrationID? {
        integrations?.selectedProviderID
    }

    var providerDescriptors: [ProviderIntegrationDescriptor] {
        ProviderIntegrationDescriptor.supported
    }

    var hasPendingProviderOperation: Bool {
        currentProviderOperation?.isTerminal == false
    }

    var canCancelProviderOperation: Bool {
        hasPendingProviderOperation && !isSubmittingProviderMutation
    }

    private let client: any OperatorManagerClientProtocol
    private let providerOperationPollIntervalNanoseconds: UInt64
    private var loadTask: Task<Void, Never>?
    private var providerRegistryTask: Task<Void, Never>?
    private var providerOperationObservationTask: Task<Void, Never>?
    private var providerMutationTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var legacyLoadGeneration = 0
    private var registryLoadGeneration = 0

    init(
        client: any OperatorManagerClientProtocol,
        providerOperationPollIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.client = client
        self.providerOperationPollIntervalNanoseconds = providerOperationPollIntervalNanoseconds
    }

    func integration(
        for providerID: ProviderIntegrationID
    ) -> ProviderIntegrationProviderSnapshot? {
        integrations?.providers.first(where: { $0.descriptor.id == providerID })
    }

    func isProviderSelected(_ providerID: ProviderIntegrationID) -> Bool {
        selectedProviderID == providerID
    }

    func isProviderToggleDisabled(_ providerID: ProviderIntegrationID) -> Bool {
        guard integrations != nil,
              providerDescriptors.first(where: { $0.id == providerID })?.selectable == true else {
            return true
        }
        return isSubmittingProviderMutation || hasPendingProviderOperation
    }

    func isProviderRemovalDisabled(_ providerID: ProviderIntegrationID) -> Bool {
        guard integrations != nil,
              selectedProviderID != providerID,
              integration(for: providerID)?.receipt != nil else {
            return true
        }
        return isSubmittingProviderMutation || hasPendingProviderOperation
    }

    func isProviderRepairAvailable(_ providerID: ProviderIntegrationID) -> Bool {
        providerDescriptors.first(where: { $0.id == providerID })?.selectable == true
    }

    func load() {
        errorMessage = nil
        noticeMessage = nil
        loadProviderRegistry()
        loadLegacyLMStudioState()
    }

    private func loadLegacyLMStudioState() {
        guard !isProbing, !isSaving, !isFetchingModels else { return }
        loadTask?.cancel()
        legacyLoadGeneration += 1
        let generation = legacyLoadGeneration
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if legacyLoadGeneration == generation {
                    isLoading = false
                }
            }
            do {
                let loadedProvider = try await client.snapshot(limit: 100).provider
                try Task.checkCancellation()
                provider = loadedProvider
                let saved = try await client.providerConfiguration()
                try Task.checkCancellation()
                apply(saved)
                if loadedProvider == nil {
                    noticeMessage = saved.saved
                        ? "LM Studio settings are saved. Use Connect and Check to verify the loaded model."
                        : "No LM Studio settings are saved. Open LM Studio Advanced to configure it."
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "LM Studio: \(error.localizedDescription)"
            }
        }
    }

    private func loadProviderRegistry() {
        providerRegistryTask?.cancel()
        providerOperationObservationTask?.cancel()
        registryLoadGeneration += 1
        let generation = registryLoadGeneration
        isLoadingProviderRegistry = true
        providerRegistryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if registryLoadGeneration == generation {
                    isLoadingProviderRegistry = false
                }
            }
            do {
                let loaded = try await client.providerIntegrations()
                try Task.checkCancellation()
                applyProviderRegistry(loaded)
                if let operation = loaded.currentOperation, !operation.isTerminal {
                    observeProviderOperation(operation)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Provider selection: \(error.localizedDescription)"
            }
        }
    }

    private func applyProviderRegistry(_ snapshot: ProviderIntegrationsSnapshot) {
        integrations = snapshot
        currentProviderOperation = snapshot.currentOperation
    }

    func setProvider(_ providerID: ProviderIntegrationID, enabled: Bool) {
        guard !isProviderToggleDisabled(providerID),
              let snapshot = integrations else { return }

        let requestedProviderID: ProviderIntegrationID?
        if enabled {
            requestedProviderID = providerID
        } else {
            guard snapshot.selectedProviderID == providerID else { return }
            requestedProviderID = nil
        }
        if enabled, providerID == .lmStudio,
           requestedProviderID != snapshot.selectedProviderID {
            connectAndCheck(activateLMStudioIfReady: true)
            return
        }
        if requestedProviderID == snapshot.selectedProviderID {
            // Legacy ledgers select LM Studio by default before a deployment receipt
            // exists. Treat an explicit ON action as Connect and Check so the first
            // interaction verifies or provisions the integration instead of no-oping.
            if enabled,
               providerID == .lmStudio,
               integration(for: providerID)?.receipt == nil {
                connectAndCheck()
            }
            return
        }

        do {
            let request = try ProviderSelectionRequest(
                expectedRevision: snapshot.selectionRevision,
                providerID: requestedProviderID,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            submitProviderOperation { [client] in
                try await client.updateProviderSelection(request)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func repairProviderIntegration(_ providerID: ProviderIntegrationID) {
        guard !isProviderToggleDisabled(providerID),
              let snapshot = integrations else { return }
        do {
            let request = try ProviderIntegrationMutationRequest(
                expectedRevision: snapshot.selectionRevision,
                providerID: providerID,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            submitProviderOperation { [client] in
                try await client.repairProviderIntegration(request)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func performProviderPrimaryAction(_ providerID: ProviderIntegrationID) {
        guard providerDescriptors.first(where: { $0.id == providerID })?.selectable == true else {
            return
        }

        guard isProviderSelected(providerID) else {
            // Activation is the manager-owned provision/inspect/select workflow.
            // Keep the card action on that path for inactive providers instead of
            // repairing an integration that is not yet the selected execution host.
            setProvider(providerID, enabled: true)
            return
        }

        if providerID == .lmStudio {
            connectAndCheck(activateLMStudioIfReady: true)
        } else {
            repairProviderIntegration(providerID)
        }
    }

    func removeProviderIntegration(_ providerID: ProviderIntegrationID) {
        guard !isProviderRemovalDisabled(providerID),
              let snapshot = integrations else { return }
        do {
            let request = try ProviderIntegrationMutationRequest(
                expectedRevision: snapshot.selectionRevision,
                providerID: providerID,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            submitProviderOperation { [client] in
                try await client.removeProviderIntegration(request)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelCurrentProviderOperation() {
        guard canCancelProviderOperation,
              let operationID = currentProviderOperation?.operationID else { return }
        submitProviderOperation { [client] in
            try await client.cancelProviderOperation(operationID: operationID)
        }
    }

    private func submitProviderOperation(
        _ request: @escaping @Sendable () async throws -> ProviderIntegrationOperationSnapshot
    ) {
        guard !isSubmittingProviderMutation else { return }
        isSubmittingProviderMutation = true
        errorMessage = nil
        noticeMessage = nil
        providerMutationTask = Task { [weak self] in
            guard let self else { return }
            defer { isSubmittingProviderMutation = false }
            do {
                let operation = try await request()
                try Task.checkCancellation()
                currentProviderOperation = operation
                if operation.isTerminal {
                    await reconcileCompletedProviderOperation(operation)
                } else {
                    observeProviderOperation(operation)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                await refreshProviderRegistryAfterOperation()
            }
        }
    }

    private func observeProviderOperation(_ operation: ProviderIntegrationOperationSnapshot) {
        providerOperationObservationTask?.cancel()
        guard !operation.isTerminal else { return }
        let operationID = operation.operationID
        providerOperationObservationTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            for _ in 0..<Self.maximumOperationPollAttempts {
                do {
                    try await Task.sleep(
                        nanoseconds: providerOperationPollIntervalNanoseconds
                    )
                    let refreshed = try await client.providerOperation(
                        operationID: operationID
                    )
                    try Task.checkCancellation()
                    consecutiveFailures = 0
                    if errorMessage?.hasPrefix("Provider setup status could not be refreshed:") == true {
                        errorMessage = nil
                    }
                    currentProviderOperation = refreshed
                    if refreshed.isTerminal {
                        await reconcileCompletedProviderOperation(refreshed)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= Self.maximumConsecutivePollFailures {
                        errorMessage = "Provider setup status could not be refreshed: \(error.localizedDescription)"
                    }
                }
            }
            noticeMessage = "Provider setup is still running. Refresh this view to resume status observation."
            await refreshProviderRegistryAfterOperation(resumeObservation: false)
        }
    }

    private func reconcileCompletedProviderOperation(
        _ operation: ProviderIntegrationOperationSnapshot
    ) async {
        await refreshProviderRegistryAfterOperation()
        switch operation.phase {
        case .active, .completed, .removed:
            noticeMessage = operation.detail ?? "Provider integration updated."
            if operation.providerID == .lmStudio,
               operation.phase != .removed {
                do {
                    let result = try await client.prepareProvider()
                    try Task.checkCancellation()
                    preparation = result
                    apply(result.configuration)
                    provider = result.provider.map(OperatorProvider.init)
                    if result.state == .ready {
                        noticeMessage = "\(operation.detail ?? "LM Studio integration updated.") Retained tasks resumed after host activation completed."
                    } else {
                        errorMessage = result.detail
                    }
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = "LM Studio was deployed, but retained tasks could not be resumed: \(error.localizedDescription)"
                }
            }
        case .awaitingUserAction:
            noticeMessage = operation.detail ?? "Provider setup needs a user action in the provider application."
        case .failedRecoverable:
            errorMessage = operation.detail ?? "Provider setup failed and can be repaired."
        case .cancelled:
            noticeMessage = operation.detail ?? "Provider setup was cancelled."
        default:
            break
        }
    }

    private func refreshProviderRegistryAfterOperation(
        resumeObservation: Bool = true
    ) async {
        do {
            let refreshed = try await client.providerIntegrations()
            try Task.checkCancellation()
            applyProviderRegistry(refreshed)
            if resumeObservation,
               let operation = refreshed.currentOperation,
               !operation.isTerminal {
                observeProviderOperation(operation)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Provider state could not be reconciled: \(error.localizedDescription)"
        }
    }

    /// Stops only local observation. The manager-owned setup operation remains durable.
    func stopObservingProviderOperation() {
        providerOperationObservationTask?.cancel()
        providerOperationObservationTask = nil
    }

    private func apply(_ value: ProviderConfigurationSnapshot) {
        configuration = value
        endpoint = value.endpoint
        modelKey = value.modelKey ?? ""
        token = ""
        credentialAction = .keep
    }

    func save() {
        guard !isBusy, let current = configuration else { return }
        let request = ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: endpoint,
            modelKey: modelKey.isEmpty ? nil : modelKey,
            credentialAction: credentialAction,
            token: credentialAction == .replace ? token : nil
        )
        token = ""
        isSaving = true
        errorMessage = nil
        noticeMessage = nil
        configurationTask = Task { [weak self] in
            guard let self else { return }
            defer { isSaving = false }
            do {
                let saved = try await client.updateProviderConfiguration(request)
                try Task.checkCancellation()
                apply(saved)
                availableModels = []
                provider = nil
                noticeMessage = saved.credentialCleanupPending
                    ? "Settings saved. Previous credential cleanup is pending; unlock Keychain and refresh. Use Connect and Check to verify usability."
                    : "Settings saved. Use Connect and Check to verify the server and loaded model."
            } catch is CancellationError {
                errorMessage = "Save was cancelled. Refresh to reconcile the saved revision before retrying."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshModels() {
        guard !isBusy, !hasUnsavedChanges, configuration?.saved == true else { return }
        isFetchingModels = true
        errorMessage = nil
        noticeMessage = nil
        configurationTask = Task { [weak self] in
            guard let self else { return }
            defer { isFetchingModels = false }
            do {
                let inventory = try await client.providerModels()
                try Task.checkCancellation()
                guard inventory.revision == configuration?.revision else {
                    throw ProviderConfigurationError.revisionConflict
                }
                availableModels = inventory.models
                if inventory.models.isEmpty {
                    noticeMessage = "The server returned no models. Add a model in LM Studio, then refresh."
                } else if !inventory.models.contains(where: { $0.loaded && $0.toolUseCapable }) {
                    noticeMessage = "LM Studio's model inventory reports no loaded tool-capable instance. Load the selected model variant in LM Studio, then refresh."
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearCredentialEntry() {
        token = ""
    }

    func cancelConfigurationRequest() {
        configurationTask?.cancel()
        token = ""
    }

    func testConnection() {
        connectAndCheck()
    }

    func connectAndCheck() {
        connectAndCheck(activateLMStudioIfReady: false)
    }

    private func connectAndCheck(activateLMStudioIfReady: Bool) {
        guard !isBusy, !hasUnsavedChanges else { return }
        loadTask?.cancel()
        probeTask?.cancel()
        isLoading = false
        isProbing = true
        errorMessage = nil
        noticeMessage = nil
        probeTask = Task { [weak self] in
            guard let self else { return }
            defer { isProbing = false }
            do {
                // Provider integration deployment may relaunch LM Studio. Keep
                // retained runs quiescent until that host transaction finishes.
                let result = try await client.prepareProviderWithoutResumingRuns()
                try Task.checkCancellation()
                preparation = result
                apply(result.configuration)
                provider = result.provider.map(OperatorProvider.init)
                if result.state == .ready {
                    noticeMessage = result.detail
                    if selectedProviderID == .lmStudio {
                        // Connect and Check proves HTTP/model readiness first. Only
                        // then deploy and verify Forge's idempotent MCP registrations.
                        repairProviderIntegration(.lmStudio)
                    } else if activateLMStudioIfReady,
                              let snapshot = integrations {
                        let request = try ProviderSelectionRequest(
                            expectedRevision: snapshot.selectionRevision,
                            providerID: .lmStudio,
                            idempotencyKey: UUID().uuidString.lowercased()
                        )
                        submitProviderOperation { [client] in
                            try await client.updateProviderSelection(request)
                        }
                    }
                } else {
                    errorMessage = result.detail
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelConnectAndCheck() {
        probeTask?.cancel()
    }

    func runContractProbe() {
        probe(.contract)
    }

    private func probe(_ mode: OperatorProviderProbeMode) {
        guard !isBusy, !hasUnsavedChanges else { return }
        loadTask?.cancel()
        probeTask?.cancel()
        isLoading = false
        isProbing = true
        errorMessage = nil
        noticeMessage = nil
        probeTask = Task { [weak self] in
            guard let self else { return }
            defer { isProbing = false }
            do {
                provider = try await client.probeProvider(
                    adapterID: ManagerNode.nativeSessionHostAdapterID,
                    mode: mode
                )
                try Task.checkCancellation()
                noticeMessage = mode == .contract
                    ? "The managed provider contract is available."
                    : "The configured provider and model are reachable."
            } catch is CancellationError {
                return
            } catch {
                let probeError = error.localizedDescription
                if let refreshed = try? await client.snapshot(limit: 100).provider {
                    provider = refreshed
                }
                errorMessage = probeError
            }
        }
    }
}
