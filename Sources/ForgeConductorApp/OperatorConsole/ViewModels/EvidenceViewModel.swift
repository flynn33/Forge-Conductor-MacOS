// EvidenceViewModel.swift
// Main-actor bounded event projection for the native evidence browser.

import Foundation

@MainActor
final class EvidenceViewModel: ObservableObject {
    private static let pageSize = 100
    private static let maximumRetainedEvents = 500

    @Published private(set) var events: [OperatorEvent] = []
    @Published var query = ""
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var filteredEvents: [OperatorEvent] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return events }
        return events.filter { event in
            [
                event.kind,
                event.summary,
                event.projectID,
                event.runID,
                event.operationID,
                event.jobID,
                event.providerRequestID,
                event.artifactID,
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.snapshot(limit: Self.pageSize, cursor: nil)
                try Task.checkCancellation()
                events = Array(snapshot.events.prefix(100))
                nextCursor = snapshot.nextCursor
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }


    func loadMore() {
        guard !isLoading, !isLoadingMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.snapshot(limit: Self.pageSize, cursor: cursor)
                let existingIDs = Set(events.map(\.eventID))
                let additions = snapshot.events.filter { !existingIDs.contains($0.eventID) }
                events = Array((events + additions).prefix(Self.maximumRetainedEvents))
                nextCursor = events.count < Self.maximumRetainedEvents ? snapshot.nextCursor : nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingMore = false
        }
    }
}
