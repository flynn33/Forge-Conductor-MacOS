// ProviderViewModel.swift
// Main-actor provider capability projection without exposing credential material.

import Foundation

@MainActor
final class ProviderViewModel: ObservableObject {
    @Published private(set) var provider: OperatorProvider?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
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
}
