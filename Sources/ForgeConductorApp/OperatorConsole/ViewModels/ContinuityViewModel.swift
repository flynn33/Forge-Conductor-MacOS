// ContinuityViewModel.swift
// Main-actor continuity and budget projection; all transitions remain manager-owned.

import Foundation

@MainActor
final class ContinuityViewModel: ObservableObject {
    @Published private(set) var operations: [OperatorContinuity] = []
    @Published private(set) var events: [OperatorEvent] = []
    @Published var selectedOperationID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedOperation: OperatorContinuity? {
        operations.first { $0.operationID == selectedOperationID }
    }

    var selectedEvents: [OperatorEvent] {
        guard let operation = selectedOperation else { return [] }
        return Array(events.filter { event in
            event.operationID == operation.operationID
                || (event.operationID == nil && event.runID == operation.runID)
        }.prefix(50))
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.snapshot(limit: 100)
                try Task.checkCancellation()
                let loadedOperations = snapshot.continuityOperations
                operations = loadedOperations
                events = Array(snapshot.events.prefix(100))
                let priorSelection = selectedOperationID
                if priorSelection == nil
                    || !loadedOperations.contains(where: { $0.operationID == priorSelection }) {
                    selectedOperationID = loadedOperations.first?.operationID
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
