// ContinuityViewModel.swift
// Main-actor continuity and budget projection; all transitions remain manager-owned.

import Foundation

@MainActor
final class ContinuityViewModel: ObservableObject {
    @Published private(set) var operations: [OperatorContinuity] = []
    @Published private(set) var runs: [OperatorRun] = []
    @Published private(set) var events: [OperatorEvent] = []
    @Published var selectedOperationID: String?
    @Published var selectedRunID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var controlInFlight: OperatorRunControlAction?
    @Published private(set) var errorMessage: String?
    @Published private(set) var commandErrorMessage: String?
    @Published private(set) var notice: String?

    private let client: any OperatorManagerClientProtocol
    private var loadTask: Task<Void, Never>?

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    var selectedOperation: OperatorContinuity? {
        operations.first { $0.operationID == selectedOperationID }
    }

    var selectedRun: OperatorRun? {
        runs.first { $0.runID == selectedRunID }
    }

    var selectedEvents: [OperatorEvent] {
        guard let operation = selectedOperation else { return [] }
        return Array(events.filter { event in
            event.operationID == operation.operationID
                || (event.operationID == nil && event.runID == operation.runID)
        }.prefix(50))
    }

    var canRequestCheckpoint: Bool { canRequest(.checkpoint) }
    var canRequestRollover: Bool { canRequest(.rollover) }

    var eligibilityMessage: String {
        if let action = controlInFlight {
            return "The manager is persisting the \(action.rawValue) request."
        }
        if isLoading {
            return "Refreshing the manager's authoritative run state."
        }
        if let reason = selectedRunEligibilityIssue {
            return reason
        }
        return "Eligible for an administrative continuity request. The manager will still verify the exact accepted session, current persisted budget observation, idle execution state, and action epoch before committing it."
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        commandErrorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.snapshot(limit: 100)
                try Task.checkCancellation()
                let loadedOperations = snapshot.continuityOperations
                let loadedRuns = snapshot.runs
                operations = loadedOperations
                runs = loadedRuns
                events = Array(snapshot.events.prefix(100))
                let priorSelection = selectedOperationID
                if priorSelection == nil
                    || !loadedOperations.contains(where: { $0.operationID == priorSelection }) {
                    selectedOperationID = loadedOperations.first?.operationID
                }
                let priorRunSelection = selectedRunID
                if priorRunSelection == nil
                    || !loadedRuns.contains(where: { $0.runID == priorRunSelection }) {
                    let selectedOperationRunID = loadedOperations.first(where: {
                        $0.operationID == self.selectedOperationID
                    })?.runID
                    selectedRunID = loadedRuns.first(where: {
                        $0.runID == selectedOperationRunID
                    })?.runID
                        ?? loadedRuns.first(where: { Self.eligibilityIssue(for: $0) == nil })?.runID
                        ?? loadedRuns.first?.runID
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func selectRun(forOperationID operationID: String?) {
        guard let operationID,
              let runID = operations.first(where: { $0.operationID == operationID })?.runID,
              runs.contains(where: { $0.runID == runID }) else {
            return
        }
        selectedRunID = runID
    }

    func requestCheckpoint() {
        request(.checkpoint)
    }

    func requestRollover() {
        request(.rollover)
    }

    private func canRequest(_ action: OperatorRunControlAction) -> Bool {
        guard action == .checkpoint || action == .rollover else { return false }
        return !isLoading && controlInFlight == nil && selectedRunEligibilityIssue == nil
    }

    private var selectedRunEligibilityIssue: String? {
        guard let selectedRun else {
            return "Select a managed run before requesting continuity."
        }
        return Self.eligibilityIssue(for: selectedRun)
    }

    private static func eligibilityIssue(for run: OperatorRun) -> String? {
        guard run.continuityMode == "managed_autonomous"
                || run.continuityMode == "managedAutonomous" else {
            return "Administrative checkpoint and rollover require managed-autonomous continuity."
        }
        guard run.state == "running" else {
            return "Run \(run.runID) must be in the running state; the manager currently reports \(run.state)."
        }
        guard run.activeSessionID != nil else {
            return "The manager has not published an accepted active session for this run."
        }
        guard run.activeOperationID == nil else {
            return "A continuity operation is already active for this run."
        }
        guard !run.continuationPending else {
            return "Automatic continuation is already pending for this run."
        }
        return nil
    }

    private func request(_ action: OperatorRunControlAction) {
        guard let run = selectedRun, canRequest(action) else { return }
        controlInFlight = action
        commandErrorMessage = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await client.controlRun(runID: run.runID, action: action)
                guard updated.runID == run.runID else {
                    throw OperatorManagerClientError.invalidPayload(
                        "manager returned run \(updated.runID) for command targeting \(run.runID)"
                    )
                }
                runs.removeAll { $0.runID == updated.runID }
                runs.insert(updated, at: 0)
                selectedRunID = updated.runID
                notice = action == .checkpoint
                    ? "Checkpoint request persisted by the manager."
                    : "Early rollover request persisted by the manager."
            } catch {
                commandErrorMessage = error.localizedDescription
            }
            controlInFlight = nil
            if commandErrorMessage == nil {
                load()
            }
        }
    }
}
