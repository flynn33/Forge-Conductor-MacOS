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

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    func load() {
        guard !isProbing else { return }
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
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func testConnection() {
        probe(.connection)
    }

    func runContractProbe() {
        probe(.contract)
    }

    private func probe(_ mode: OperatorProviderProbeMode) {
        guard !isProbing else { return }
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
