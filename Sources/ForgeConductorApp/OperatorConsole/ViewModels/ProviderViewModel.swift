// ProviderViewModel.swift
// Main-actor provider capability projection without exposing credential material.

import Foundation
import ForgeConductorCore

@MainActor
final class ProviderViewModel: ObservableObject {
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
    private var configurationTask: Task<Void, Never>?

    var isBusy: Bool { isLoading || isProbing || isSaving || isFetchingModels }
    var hasUnsavedChanges: Bool {
        guard let configuration else { return false }
        return endpoint != configuration.endpoint || modelKey != (configuration.modelKey ?? "")
            || credentialAction != .keep
    }

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    func load() {
        guard !isProbing, !isSaving, !isFetchingModels else { return }
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        noticeMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedProvider = try await client.snapshot(limit: 100).provider
                try Task.checkCancellation()
                provider = loadedProvider
                if loadedProvider == nil {
                    errorMessage = "The manager did not publish a provider capability snapshot."
                }
                let saved = try await client.providerConfiguration()
                try Task.checkCancellation()
                apply(saved)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
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
        let request = ProviderConfigurationUpdate(expectedRevision: current.revision,
            endpoint: endpoint, modelKey: modelKey.isEmpty ? nil : modelKey,
            credentialAction: credentialAction, token: credentialAction == .replace ? token : nil)
        token = ""
        isSaving = true
        errorMessage = nil; noticeMessage = nil
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
                    ? "Settings saved. Previous credential cleanup is pending; unlock Keychain and refresh. Test Connection to verify usability."
                    : "Settings saved. Test Connection to verify the server and loaded model."
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
        errorMessage = nil; noticeMessage = nil
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
                    noticeMessage = "No tool-capable model is loaded. Load a supported model in LM Studio, then refresh."
                }
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func clearCredentialEntry() { token = "" }

    func cancelConfigurationRequest() {
        configurationTask?.cancel()
        token = ""
    }

    func testConnection() {
        probe(.connection)
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
