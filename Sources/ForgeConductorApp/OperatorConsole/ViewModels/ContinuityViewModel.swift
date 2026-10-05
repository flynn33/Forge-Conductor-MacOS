// ContinuityViewModel.swift
// Project-scoped continuity packet inventory with exact packet deletion.

import Foundation
import ForgeConductorCore

@MainActor
final class ContinuityViewModel: ObservableObject {
    @Published private(set) var projectIDs: [String] = []
    @Published var selectedProjectID: String?
    @Published private(set) var packets: [OperatorContinuityPacket] = []
    @Published var selectedPacketIDs = Set<String>()
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPackets = false
    @Published private(set) var deletingPacketIDs = Set<String>()
    @Published private(set) var isResetting = false
    @Published private(set) var isClearingCache = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var commandErrorMessage: String?
    @Published private(set) var notice: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?
    private var packetTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var canDeleteSelectedPackets: Bool {
        !selectedPacketIDs.isEmpty && !isLoadingPackets && deletingPacketIDs.isEmpty
    }

    var canResetSelectedProject: Bool {
        selectedProjectID != nil && !isLoadingPackets && !isResetting
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
                // Packet management remains available when automatic continuity
                // is idle or unavailable. Durable packets outlive the automation
                // state that created them, so every registered project is a valid
                // packet-list scope.
                let loadedProjectIDs = snapshot.projects
                    .map { $0.projectID.lowercased() }
                    .sorted()
                projectIDs = loadedProjectIDs
                if let selectedProjectID, loadedProjectIDs.contains(selectedProjectID) {
                    self.selectedProjectID = selectedProjectID
                } else {
                    selectedProjectID = loadedProjectIDs.first
                }
                loadPackets()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func loadPackets() {
        packetTask?.cancel()
        selectedPacketIDs.removeAll()
        packets = []
        guard let projectID = selectedProjectID else {
            isLoadingPackets = false
            return
        }
        isLoadingPackets = true
        commandErrorMessage = nil
        packetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.continuityPackets(projectID: projectID)
                try Task.checkCancellation()
                guard response.projectID.description == projectID else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager returned continuity packets for another project"
                    )
                }
                packets = response.packets
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                commandErrorMessage = error.localizedDescription
            }
            isLoadingPackets = false
        }
    }

    func deleteSelectedPackets() {
        guard canDeleteSelectedPackets,
              let projectID = selectedProjectID,
              let projectUUID = UUID(uuidString: projectID) else {
            commandErrorMessage = "Select one or more continuity packets to delete."
            return
        }
        let selection = packets.map(\.packetID).filter(selectedPacketIDs.contains)
        guard selection.count == selectedPacketIDs.count else {
            commandErrorMessage = "The selected continuity packet list changed. Reload and retry."
            return
        }
        deletingPacketIDs = Set(selection)
        commandErrorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = OperatorContinuityPacketDeleteRequest(
                    projectID: ProjectID(projectUUID),
                    packetIDs: selection
                )
                let receipt = try await client.deleteContinuityPackets(request)
                guard Set(receipt.deletedPacketIDs) == Set(selection) else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager did not delete the exact continuity packet selection"
                    )
                }
                packets.removeAll { selection.contains($0.packetID) }
                selectedPacketIDs.removeAll()
                notice = selection.count == 1
                    ? "Deleted continuity packet \(selection[0])."
                    : "Deleted \(selection.count) continuity packets."
            } catch {
                commandErrorMessage = error.localizedDescription
            }
            deletingPacketIDs.removeAll()
            if commandErrorMessage == nil { loadPackets() }
        }
    }

    func resetSelectedProjectContinuity() {
        guard canResetSelectedProject,
              let projectID = selectedProjectID,
              let projectUUID = UUID(uuidString: projectID) else {
            commandErrorMessage = "Select a continuity project to reset."
            return
        }
        isResetting = true
        commandErrorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = ContinuityHistoryClearRequest(
                    scope: .project,
                    projectID: ProjectID(projectUUID)
                )
                let receipt = try await client.clearContinuityHistory(request)
                guard receipt.scope == .project,
                      receipt.requestedProjectID == request.projectID else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager returned a continuity reset receipt for another project"
                    )
                }
                notice = "Reset continuity history for project \(projectID). "
                    + "Durable packets remain available until explicitly deleted."
                loadPackets()
            } catch {
                commandErrorMessage = error.localizedDescription
            }
            isResetting = false
        }
    }

    func clearDisposableCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        commandErrorMessage = nil
        notice = nil
        let operationID = UUID()
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await client.clearApplicationCache(operationID: operationID)
                guard receipt.operationID == operationID, receipt.removedEntryCount >= 0 else {
                    throw OperatorManagerClientError.invalidPayload(
                        "cache clear receipt did not match the requested operation"
                    )
                }
                notice = "Cleared disposable Forge cache (\(receipt.removedEntryCount) top-level item(s))."
            } catch {
                commandErrorMessage = error.localizedDescription
            }
            isClearingCache = false
        }
    }
}
